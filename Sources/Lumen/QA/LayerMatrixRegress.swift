import AppKit
import CoreImage
import ImageCratCore

/// Named regression checks for the bugs found by the layer matrix. They are fast and always run with `qalayers`.
enum LQARegressions {
    static let G = "regress"
    static var subjects: [String: QASubject] = [:]

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") { LQA.check(ok, "\(G): \(name)", "", detail()) }

    static func make(_ name: String) -> (DocumentState, [UUID]) {
        if subjects.isEmpty { for s in QASubjects.all() { subjects[s.name] = s } }
        return subjects[name]!.make()
    }

    static func same(_ a: DocumentState, _ b: DocumentState, _ name: String, mean: Double = 0.6, bad: Double = 0.004, blur: Double = 0) {
        let ia = LQA.render(a, blur: blur), ib = LQA.render(b, blur: blur)
        let df = LQA.diff(ia, ib)
        let ok = df.within(mean: mean, bad: bad)
        if !ok { LQA.dumpPair(ia, ib, "regress_" + name) }
        check(ok, name, df.description)
    }

    static func bounds(_ st: DocumentState, _ id: UUID) -> CGRect { st.layer(id).flatMap { Compositor.shared.contentBounds($0, state: st) } ?? .null }

    static func run() {
        if LQA.env["LUMEN_QA_DEBUG"] == "1" { return }
        let all: [(String, () -> Void)] = [
            ("bounds", boundsChecks), ("artboard", artboardFromLayers), ("history", historySteps), ("smartobject", smartObjectConversion),
            ("rasterize", rasterize), ("group", grouping), ("rotate", rotateHalfTurn), ("comps", layerComps), ("warp", warps), ("emboss", embossAlpha),
            ("paragraph", paragraphConversion), ("psd", psd), ("imagesize", imageSize), ("stored", storedData), ("duplicate", duplicateDocument),
            ("merge", mergeVisible), ("selection", nestedAndLinkedSelection), ("frames", animationFrames), ("lumen", richDocumentRoundTrip),
        ]
        for (name, body) in all where LQA.cmdFilter.map({ name.contains($0.lowercased()) }) ?? true {
            body()
            Compositor.shared.clearCaches()
        }
    }

    // MARK: Bounds and handles

    static func boundsChecks() {
        // A stroke inside the path does not enlarge the shape: Align must put the drawn edge on the canvas edge.
        var (st, ids) = make("shape.stroke.inside")
        LQA.withDoc(st, select: ids) { d in
            AppActions.align(.left)
            let ab = LQA.alphaBounds(d.state.layer(ids[0])!, d.state) ?? .null
            check(abs(ab.minX) <= 1, "Align Left puts a shape with an inside stroke on the canvas edge", "drawn from x = \(ab.minX)")
        }
        // A mesh-warped smart object: bounds and transform box follow what is drawn.
        (st, ids) = make("smart.warp")
        LQA.withDoc(st, select: ids) { d in
            let l = d.state.layer(ids[0])!
            let cb = bounds(d.state, ids[0]), ab = LQA.alphaBounds(l, d.state) ?? .null
            check(LQA.close(cb, ab, 3), "warped smart object: bounds match the drawn pixels", "\(LQA.fmt(cb)) vs \(LQA.fmt(ab))")
            if let q = QATransforms.sessionQuad(d, ids) { check(LQA.close(q.bounds, cb, 0.5), "warped smart object: the transform box encloses the warped content", LQA.fmt(q.bounds)) }
            let before = d.state
            AppActions.convertToSmartObject()
            same(before, d.state, "warped smart object → smart object keeps the warped parts")
        }
        // An artboard draws (and clips to) its rectangle.
        (st, ids) = make("artboard")
        let rect = st.layer(ids[0])!.artboard!.rect
        check(bounds(st, ids[0]) == rect, "artboard bounds are its rectangle", LQA.fmt(bounds(st, ids[0])))
        LQA.withDoc(st, select: ids) { d in
            // the rectangle must not grow through float noise (440.00000000000006 → 441)
            if let b = QATransforms.unionBounds(d.state, ids) { QATransforms.apply(QATransforms.named("scale2.2").make(b), doc: d, ids: ids) }
            QATransforms.apply(Homography(affine: CGAffineTransform(translationX: 21, y: 13)), doc: d, ids: ids)
            let r = d.state.layer(ids[0])!.artboard!.rect
            check(r.size == CGSize(width: (rect.width * 2.2).rounded(), height: (rect.height * 2.2).rounded()), "artboard keeps its size when it is moved after scaling", LQA.fmt(r))
        }
    }

    static func artboardFromLayers() {
        let (st, ids) = make("shape.rounded")
        LQA.withDoc(st, select: ids) { d in
            let h0 = d.history.count
            AppActions.artboardFromLayers()          // used to trap (overlapping access to the document state)
            check(d.activeLayer?.isArtboard == true, "Artboard from Layers creates an artboard")
            check(d.history.count == h0 + 1, "Artboard from Layers is one history step", "\(d.history.count - h0)")
            d.undo()
            check(LQA.Snapshot(d.state).matches(LQA.Snapshot(st)), "undo of Artboard from Layers restores the layers")
        }
    }

    static func historySteps() {
        var (st, ids) = make("raster.small")
        QALayerCommands.rectSelection(&st)
        LQA.withDoc(st, select: ids) { d in
            let h0 = d.history.count
            AppActions.layerViaCopy(cut: true)
            check(d.history.count == h0 + 1, "Layer via Cut is one history step", "\(d.history.count - h0)")
        }
        (st, ids) = make("raster.small")
        LQA.withDoc(st, select: ids) { d in
            let h0 = d.history.count
            AppActions.convertMode(.grayscale)
            check(d.history.count == h0 + 1 && d.state.colorMode == .grayscale, "Mode ▸ Grayscale is one history step", "\(d.history.count - h0)")
        }
    }

    // MARK: Convert to Smart Object

    static func smartObjectConversion() {
        func convert(_ name: String, _ what: String, mean: Double = 0.6, extra: (Document, DocumentState) -> Void = { _, _ in }) {
            let (st, ids) = make(name)
            LQA.withDoc(st, select: ids) { d in
                AppActions.convertToSmartObject()
                same(st, d.state, what, mean: mean)
                extra(d, st)
            }
        }
        convert("clip.clipped.raster", "clipped layer → smart object stays clipped") { d, _ in check(d.activeLayer?.isClipped == true, "smart object takes over the clipping flag") }
        convert("blend.multiply.shape", "Multiply layer → smart object keeps blending with the layers below") { d, _ in check(d.activeLayer?.blendMode == .multiply, "smart object takes over the blend mode") }
        convert("blendif.raster", "Blend If layer → smart object keeps its Blend If")
        convert("channels.raster", "channel-restricted layer → smart object keeps the restriction")
        convert("knockout.deep.text", "knockout layer → smart object still knocks out")
        convert("mask.unlinked.text", "layer with an unlinked mask → smart object keeps the mask aligned")
        convert("fx.globalLight.text", "layer style using Global Light → smart object keeps the light angle")
        convert("hidden.text", "hidden layer → smart object stays hidden") { d, _ in check(d.activeLayer?.isVisible == false, "smart object of a hidden layer is hidden (its content is not)") }
        convert("label.shape", "colour-labelled layer → smart object") { d, _ in check(d.activeLayer?.colorLabel == .red, "smart object keeps the colour label") }

        // a group selected together with one of its children: the child must not be doubled
        var (st, ids) = make("group.passthrough")
        let child = st.layer(ids[0])!.children[0].id
        LQA.withDoc(st, select: [ids[0], child]) { d in
            AppActions.convertToSmartObject()
            same(st, d.state, "group + one of its layers → smart object (no duplicated layer)")
            if case .document(let inner)? = d.activeLayer?.smart?.source { check(inner.allLayers.filter { $0.id == child }.count == 1, "the selected child is inside the smart object once") }
        }
        // base + clipped layers converted together keep clipping inside
        (st, ids) = make("clip.base")
        let stack = st.layers.suffix(3).map(\.id)
        LQA.withDoc(st, select: Array(stack)) { d in
            AppActions.convertToSmartObject()
            if case .document(let inner)? = d.activeLayer?.smart?.source {
                check(inner.layers.count == 3 && !inner.layers[0].isClipped && inner.layers[1].isClipped, "clipping stack converted together stays a clipping stack inside")
            }
        }
        // effects of layers inside a group need room in the smart object
        var shadowed = QASubjects.shape(.rectangle(QASubjects.shapeRect, cornerRadius: 0))
        shadowed.effects = QASubjects.fx { $0.dropShadow.enabled = true; $0.dropShadow.distance = 16; $0.dropShadow.size = 6; $0.dropShadow.blendMode = .normal; $0.dropShadow.color = RGBA(hex: "C2185B")! }
        let g = Layer(name: "Group", content: .group(GroupContent(children: [shadowed])))
        st = QASubjects.base(); st.layers.append(g)
        LQA.withDoc(st, select: [g.id]) { d in
            AppActions.convertToSmartObject()
            same(st, d.state, "group with a drop-shadowed layer → smart object keeps the whole shadow")
        }
        // smart filters draw beyond the object's box
        var blurred = QASubjects.smartImage()
        var f = FilterInstance(kind: .gaussianBlur); f.values["radius"] = 12
        blurred.smart?.filters = [f]
        st = QASubjects.base(); st.layers.append(blurred)
        LQA.withDoc(st, select: [blurred.id]) { d in
            AppActions.convertToSmartObject()
            same(st, d.state, "smart object with a Gaussian Blur filter → smart object keeps the blur halo", mean: 0.4, bad: 0.002)
        }
        // scale up → convert → scale down equals converting directly (the reported case, generalized)
        for name in ["text.point", "text.warp.arc", "shape.rounded", "smart.rotated"] {
            let (s0, i0) = make(name)
            let direct = LQA.withDoc(s0, select: i0) { d -> PixelBuffer in AppActions.convertToSmartObject(); return LQA.render(d.state, blur: 1) }
            LQA.withDoc(s0, select: i0) { d in
                guard let b = QATransforms.unionBounds(d.state, i0) else { return }
                QATransforms.apply(QATransforms.around(b.origin, CGAffineTransform(scaleX: 2.2, y: 2.2)), doc: d, ids: i0)
                AppActions.convertToSmartObject()
                let so = [d.activeLayerID!]
                let big = bounds(d.state, so[0])
                check(big.width > b.width * 2, "\(name): smart object of a scaled layer has the scaled size", LQA.fmt(big))
                QATransforms.apply(QATransforms.around(b.origin, CGAffineTransform(scaleX: 1 / 2.2, y: 1 / 2.2)), doc: d, ids: so)
                let df = LQA.diff(direct, LQA.render(d.state, blur: 1))
                check(df.within(mean: 1.0, bad: 0.006), "\(name): scale up → smart object → scale down equals converting directly", df.description)
            }
        }
    }

    // MARK: Rasterize

    static func rasterize() {
        var (st, ids) = make("fillopacity.text")
        LQA.withDoc(st, select: ids) { d in
            AppActions.rasterizeLayer(ids[0])
            check(d.state.layer(ids[0])?.fillOpacity == 0.3, "Rasterize Layer keeps the fill opacity as a layer attribute")
            same(st, d.state, "Rasterize Layer keeps the look of a layer with fill opacity and a stroke effect")
        }
        (st, ids) = make("hidden.text")
        LQA.withDoc(st, select: ids) { d in
            AppActions.rasterizeLayer(ids[0])
            let b = bounds(d.state, ids[0])
            check(!b.isNull && b.width > 50, "Rasterize Layer keeps the pixels of a hidden layer", LQA.fmt(b))
        }
        // apply the mask of a hidden pixel layer
        (st, ids) = make("mask.linked.raster")
        st.updateLayer(ids[0]) { $0.isVisible = false }
        LQA.withDoc(st, select: ids) { d in
            AppActions.applyMask()
            let b = bounds(d.state, ids[0])
            check(!b.isNull && b.width > 20, "Apply Layer Mask keeps the pixels of a hidden layer", LQA.fmt(b))
        }
        // content beyond the canvas survives rasterizing
        let off = QASubjects.text("Off canvas text", size: 40, at: CGPoint(x: -150, y: 100))
        st = QASubjects.base(); st.layers.append(off)
        var movedFirst = st
        movedFirst.updateLayer(off.id) { $0.translate(dx: 170, dy: 0) }
        LQA.withDoc(st, select: [off.id]) { d in
            AppActions.rasterizeLayer(off.id)
            d.updateLayer(off.id) { $0.translate(dx: 170, dy: 0) }
            same(movedFirst, d.state, "Rasterize Layer keeps the part of a type layer that is off the canvas", mean: 0.5, bad: 0.004)
        }
        LQA.withDoc(st, select: [off.id]) { d in
            d.updateLayer(off.id) { $0.effects = QASubjects.fx { $0.stroke.enabled = true; $0.stroke.size = 3; $0.stroke.paint = .color(.white) } }
            var want = d.state
            want.updateLayer(off.id) { $0.translate(dx: 170, dy: 0) }
            AppActions.rasterizeLayerStyle()
            d.updateLayer(off.id) { $0.translate(dx: 170, dy: 0) }
            same(want, d.state, "Rasterize Layer Style keeps the off-canvas part too", mean: 0.6, bad: 0.005)
        }
        // style + mask: effects come from the masked shape
        (st, ids) = make("mask.fx.stroke.shape")
        LQA.withDoc(st, select: ids) { d in
            AppActions.rasterizeLayerStyle()
            let l = d.state.layer(ids[0])!
            check(l.mask == nil && !l.effects.hasAny, "Rasterize Layer Style merges the style and the mask into the pixels")
            same(st, d.state, "Rasterize Layer Style keeps the look of a masked layer with a stroke", mean: 0.8, bad: 0.006)
        }
        // Global Light
        (st, ids) = make("fx.globalLight.text")
        LQA.withDoc(st, select: ids) { d in
            AppActions.rasterizeLayerStyle()
            same(st, d.state, "Rasterize Layer Style uses the document's Global Light", mean: 0.8, bad: 0.006)
        }
        LQA.withDoc(st, select: ids) { d in
            AppActions.mergeDown()
            same(st, d.state, "Merge Down uses the document's Global Light", mean: 0.8, bad: 0.006)
        }
    }

    // MARK: Groups and clipping

    static func grouping() {
        let (st, ids) = make("clip.clipped.text")
        LQA.withDoc(st, select: ids) { d in
            AppActions.groupLayers()
            check(d.activeLayer?.isClipped == true, "grouping a clipped layer: the group takes over the clipping")
            same(st, d.state, "grouping a clipped layer keeps it clipped to its base")
            AppActions.ungroupLayers()
            check(d.state.layer(ids[0])?.isClipped == true, "ungrouping a clipped group puts the layer back into the clipping stack")
            same(st, d.state, "group then ungroup of a clipped layer restores the look")
        }
    }

    static func rotateHalfTurn() {
        for name in ["text.runs", "raster.small", "shape.ellipse"] {
            let (st, ids) = make(name)
            LQA.withDoc(st, select: ids) { d in
                let b0 = bounds(d.state, ids[0])
                AppActions.rotateLayers(degrees: 180); AppActions.rotateLayers(degrees: 180)
                let b1 = bounds(d.state, ids[0])
                check(LQA.close(b0, b1, 0.01), "\(name): Rotate 180° twice puts the layer back exactly", "\(LQA.fmt(b0)) → \(LQA.fmt(b1))")
            }
        }
    }

    // MARK: Layer comps

    static func layerComps() {
        for name in ["fill.solid", "adjustment.invert", "group.normal", "frame.image", "artboard"] {
            let (st, ids) = make(name)
            LQA.withDoc(st, select: ids) { d in
                AppActions.newLayerComp()
                d.updateLayer(ids[0]) { $0.translate(dx: 31, dy: -18) }
                d.commit("Move")
                AppActions.applyLayerComp(d.state.layerComps[0].id)
                same(st, d.state, "\(name): applying a layer comp restores masks / artboard frame that moved with the layer")
                // Update Layer Comp captures the new place
                d.updateLayer(ids[0]) { $0.translate(dx: 12, dy: 9) }
                d.commit("Move")
                let moved = d.state
                AppActions.updateLayerComp(d.state.layerComps[0].id)
                d.updateLayer(ids[0]) { $0.translate(dx: -40, dy: 20) }
                d.commit("Move")
                AppActions.applyLayerComp(d.state.layerComps[0].id)
                same(moved, d.state, "\(name): an updated layer comp restores the updated position")
            }
        }
    }

    // MARK: Warp

    static func warps() {
        // a rectangle has four anchor points: mapping only those leaves it unwarped
        var (st, ids) = make("shape.rect")
        LQA.withDoc(st, select: ids) { d in
            let b0 = bounds(d.state, ids[0])
            QATransforms.warp(doc: d, id: ids[0], style: .arc, bend: 0.5)
            let b1 = bounds(d.state, ids[0])
            check(b1.minY < b0.minY - 8 && d.state.layer(ids[0])?.isShape == true, "Warp (Arc) bends the straight edges of a rectangle shape", "\(LQA.fmt(b0)) → \(LQA.fmt(b1))")
            QATransforms.checkGeometry(d.state.layer(ids[0])!, d.state, subject: QASubject(name: "shape", make: { (st, ids) }), label: "warped rectangle", check: "\(G): warped shape bounds match the drawn pixels")
        }
        // a shape with a perspective transform: the warp must not apply the perspective twice
        (st, ids) = make("shape.rounded")
        LQA.withDoc(st, select: ids) { d in
            guard let b = QATransforms.unionBounds(d.state, ids) else { return }
            QATransforms.apply(QATransforms.named("perspective").make(b), doc: d, ids: ids)
            let before = bounds(d.state, ids[0])
            // identity-like warp: bend 0 keeps every point
            QATransforms.warp(doc: d, id: ids[0], style: .arc, bend: 0)
            let after = bounds(d.state, ids[0])
            check(LQA.close(before, after, 1), "warping a shape that has a perspective transform keeps it in place", "\(LQA.fmt(before)) → \(LQA.fmt(after))")
            check(d.state.layer(ids[0])?.shape?.perspective == nil, "the perspective is baked into the warped path once")
        }
        // masks linked to the layer follow the warp
        (st, ids) = make("mask.linked.raster")
        LQA.withDoc(st, select: ids) { d in
            let m0 = d.state.layer(ids[0])!.mask!
            let top0 = LQA.opaqueBounds(m0.buffer, threshold: 128).map { $0.y + m0.origin.y } ?? 0
            QATransforms.warp(doc: d, id: ids[0], style: .arc, bend: 0.6)
            let m1 = d.state.layer(ids[0])!.mask!
            let top1 = LQA.opaqueBounds(m1.buffer, threshold: 128).map { $0.y + m1.origin.y } ?? 0
            check(top1 < top0 - 4, "a linked layer mask is warped with the layer", "mask top \(top0) → \(top1)")
        }
        (st, ids) = make("vmask.raster")
        LQA.withDoc(st, select: ids) { d in
            let v0 = d.state.layer(ids[0])!.vectorMask!.bounds
            QATransforms.warp(doc: d, id: ids[0], style: .arc, bend: 0.6)
            let v1 = d.state.layer(ids[0])!.vectorMask!.bounds
            check(v1.minY < v0.minY - 2, "a vector mask is warped with the layer", "\(LQA.fmt(v0)) → \(LQA.fmt(v1))")
        }
        // warp, rotate, warp again: the second warp composes on the rotated mesh
        (st, ids) = make("smart.warp")
        LQA.withDoc(st, select: ids) { d in
            guard let b = QATransforms.unionBounds(d.state, ids) else { return }
            QATransforms.apply(QATransforms.named("rotate33").make(b), doc: d, ids: ids)
            QATransforms.warp(doc: d, id: ids[0], style: .flag, bend: 0.5)
            let cb = bounds(d.state, ids[0]), ab = LQA.alphaBounds(d.state.layer(ids[0])!, d.state) ?? .null
            check(LQA.close(cb.intersection(d.state.canvasCGRect), ab.intersection(d.state.canvasCGRect), 3.5), "warp → rotate → warp: bounds still match the drawn pixels", "\(LQA.fmt(cb)) vs \(LQA.fmt(ab))")
        }
    }

    static func embossAlpha() {
        let buf = QASubjects.image(120, 80)
        let sp = CanvasSpace(width: 120, height: 80)
        let out = RenderEngine.renderBuffer(FilterInstance(kind: .emboss).apply(buf.ciImage, canvas: sp.ciCanvas), docRect: IRect(x: 0, y: 0, width: 120, height: 80), space: sp)
        let p = out.pixel(60, 40)
        check(p.3 == 255, "Emboss keeps an opaque layer opaque", "alpha \(p.3)")
        // as a smart filter the result survives rasterizing
        var so = QASubjects.smartImage()
        so.smart?.filters = [FilterInstance(kind: .emboss)]
        var st = QASubjects.base(); st.layers.append(so)
        LQA.withDoc(st, select: [so.id]) { d in
            guard let b = QATransforms.unionBounds(d.state, [so.id]) else { return }
            QATransforms.apply(QATransforms.named("scale2.2").make(b), doc: d, ids: [so.id])
            st = d.state
            AppActions.rasterizeLayer(so.id)
            same(st, d.state, "rasterizing a smart object with an Emboss smart filter keeps its look")
        }
    }

    static func paragraphConversion() {
        for align in [TextAlign.center, .right] {
            let l = QASubjects.text("Centred point\ntext lines", size: 30, at: CGPoint(x: 90, y: 80)) { $0.alignment = align }
            var st = QASubjects.base(); st.layers.append(l)
            LQA.withDoc(st, select: [l.id]) { d in
                TypeActions2.convert("Convert to Paragraph Text") { $0.convertToParagraphText() }
                check(d.state.layer(l.id)?.text?.boxSize != nil, "\(align.rawValue)-aligned point text becomes paragraph text")
                same(st, d.state, "Convert to Paragraph Text keeps \(align.rawValue)-aligned lines in place", mean: 0.3, bad: 0.002)
            }
        }
    }

    // MARK: PSD

    static func psd() {
        func roundTrip(_ name: String, _ what: String, mean: Double = 1.2, extra: (DocumentState, DocumentState) -> Void = { _, _ in }) {
            let (st, _) = make(name)
            let url = LQA.out.appendingPathComponent("qa_regress.psd")
            guard (try? PSDWriter.write(st, to: url)) != nil, let back = try? PSDReader.read(url: url) else { check(false, what, "export / import failed"); return }
            same(st, back, what, mean: mean, bad: 0.008)
            extra(st, back)
        }
        roundTrip("group.normal", "PSD keeps a group's layer mask") { _, b in check(b.allLayers.first { $0.isGroup }?.mask != nil, "PSD import restores the group mask") }
        roundTrip("mask.disabled.raster", "PSD keeps a disabled layer mask disabled") { _, b in check(b.allLayers.last?.mask?.isEnabled == false, "PSD import restores the disabled flag") }
        roundTrip("vmask.raster", "PSD keeps the vector mask of a pixel layer")
        roundTrip("frame.image", "PSD keeps the vector mask of a group / frame")
        roundTrip("mask.feather.shape", "PSD keeps mask feather and density")
        roundTrip("fillopacity.text", "PSD keeps fill opacity next to the layer style") { a, b in check(abs((b.allLayers.last?.fillOpacity ?? 1) - (a.allLayers.last?.fillOpacity ?? 0)) < 0.01, "PSD import restores the fill opacity") }
        roundTrip("fx.globalLight.text", "PSD keeps the Global Light angle") { a, b in check(b.globalLight == a.globalLight, "PSD import restores Global Light", "\(b.globalLight)") }
        roundTrip("hidden.text", "PSD keeps a hidden type layer") { a, b in check(b.allLayers.contains { $0.name == "Type" && !$0.isVisible }, "PSD import finds the hidden layer") }
        // a clipped group
        var (st, ids) = make("clip.clipped.raster")
        LQA.withDoc(st, select: ids) { d in AppActions.groupLayers(); st = d.state }
        let url = LQA.out.appendingPathComponent("qa_regress.psd")
        if (try? PSDWriter.write(st, to: url)) != nil, let back = try? PSDReader.read(url: url) {
            check(back.allLayers.first { $0.isGroup }?.isClipped == true, "PSD keeps a clipped group clipped")
            same(st, back, "PSD keeps the look of a clipped group", mean: 1.2, bad: 0.008)
        }
        _ = ids
    }

    // MARK: Image Size / canvas rotation

    static func imageSize() {
        var (st, ids) = make("shape.stroke.center")
        LQA.withDoc(st, select: ids) { d in
            AppActions.imageSize(width: LQA.W * 2, height: LQA.H * 2, resolution: 72, scaleStyles: false)
            check(d.state.layer(ids[0])?.shape?.stroke.width == 16, "Image Size scales a shape's stroke even with Scale Styles off", "\(d.state.layer(ids[0])?.shape?.stroke.width ?? 0)")
        }
        // gradients without placed end points rotate / flip with the canvas
        for name in ["fill.gradient", "shape.gradient"] {
            (st, ids) = make(name)
            LQA.withDoc(st, select: ids) { d in
                let img0 = LQA.render(d.state)
                AppActions.rotateCanvas(90)
                let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(LQA.H), ty: 0)
                let want = QADocumentCommands.mapped(img0, Homography(affine: t), from: st, size: (LQA.H, LQA.W), blur: 0.8, nearest: true)
                let df = LQA.diff(want, LQA.render(d.state, blur: 0.8))
                check(df.within(mean: 1.2, bad: 0.01), "\(name): the gradient turns with Rotate Canvas 90°", df.description)
                AppActions.rotateCanvas(-90)
                let df2 = LQA.diff(img0, LQA.render(d.state))
                check(df2.within(mean: 0.5, bad: 0.004), "\(name): rotating the canvas back restores the gradient", df2.description)
            }
        }
    }

    // MARK: Data stored outside the layers

    static func storedData() {
        var (st, ids) = make("raster.small")
        st.toolData.slices = [DocSlice(rect: CGRect(x: 80, y: 70, width: 140, height: 90), name: "s")]
        st.toolData.colorSamplers = [CGPoint(x: 100, y: 90)]
        var stB = st
        stB.updateLayer(ids[0]) { $0.translate(dx: 40, dy: 30) }
        st.frames = [Animation.capture(st), Animation.capture(stB)]
        LQA.withDoc(st, select: ids) { d in
            AppActions.imageSize(width: LQA.W * 2, height: LQA.H * 2, resolution: 72, scaleStyles: true)
            check(d.state.toolData.slices.first?.rect == CGRect(x: 160, y: 140, width: 280, height: 180), "Image Size scales slices with the document", "\(d.state.toolData.slices.first?.rect ?? .zero)")
            // samplers snap to the centre of the pixel they land on (ToolDocData.mapped)
            check(d.state.toolData.colorSamplers.first.map { abs($0.x - 200) <= 0.5 && abs($0.y - 180) <= 0.5 } ?? false, "Image Size scales colour samplers with the document")
            check(d.state.frames.count == 2 && d.state.frames[1].positions[ids[0]] == CGPoint(x: 240, y: 200), "Image Size scales the layer positions stored in animation frames",
                  "\(d.state.frames.last?.positions[ids[0]] ?? .zero)")
            AppActions.canvasSize(width: LQA.W * 2 + 100, height: LQA.H * 2 + 60, anchorX: 2, anchorY: 2, extension: nil)
            check(d.state.frames[1].positions[ids[0]] == CGPoint(x: 340, y: 260), "Canvas Size shifts the layer positions stored in animation frames", "\(d.state.frames[1].positions[ids[0]] ?? .zero)")
            check(d.state.toolData.slices.first?.rect.origin == CGPoint(x: 260, y: 200), "Canvas Size shifts slices with the document")
        }
    }

    static func duplicateDocument() {
        var (st, ids) = make("generative")
        st.frames = [Animation.capture(st)]
        LQA.withDoc(st, select: ids) { d in
            AppActions.newLayerComp()
            AppActions.duplicateDocument()
            guard let copy = AppModel.shared.activeDocument, copy !== d else { check(false, "Duplicate Document creates a document"); return }
            defer { AppModel.shared.close(copy); AppModel.shared.activeDocumentID = d.id }
            let layerIDs = Set(copy.state.allLayers.map(\.id))
            check(Set(copy.state.layerComps[0].entries.keys).isSubset(of: layerIDs), "Duplicate Document keeps layer comps attached to their layers")
            check(Set(copy.state.frames[0].visibility.keys).isSubset(of: layerIDs), "Duplicate Document keeps animation frames attached to their layers")
            check(Set(copy.state.generative.keys).isSubset(of: layerIDs) && !copy.state.generative.isEmpty, "Duplicate Document keeps generative-layer metadata attached")
            check(copy.state.layer(ids[0])?.raster?.buffer !== d.state.layer(ids[0])?.raster?.buffer, "Duplicate Document copies the pixels")
        }
    }

    static func mergeVisible() {
        var (st, ids) = make("group.passthrough")
        let hiddenChild = st.layer(ids[0])!.children[1].id
        st.updateLayer(hiddenChild) { $0.isVisible = false }
        var top = QASubjects.rasterSmall("Hidden top"); top.isVisible = false
        st.layers.append(top)
        LQA.withDoc(st, select: ids) { d in
            AppActions.mergeVisible()
            check(d.state.layer(top.id) != nil, "Merge Visible keeps a hidden top-level layer")
            check(d.state.layer(hiddenChild) != nil && d.state.layer(hiddenChild)?.isVisible == false, "Merge Visible keeps a hidden layer inside a visible group")
            same(st, d.state, "Merge Visible keeps the look", mean: 0.3, bad: 0.001)
        }
    }

    // MARK: Nested and linked selections

    static func nestedAndLinkedSelection() {
        var (st, ids) = make("group.passthrough")
        let child = st.layer(ids[0])!.children[0].id
        let both = [ids[0], child]
        let b0 = bounds(st, child)
        LQA.withDoc(st, select: both) { d in
            QATransforms.apply(Homography(affine: CGAffineTransform(translationX: 30, y: 20)), doc: d, ids: both)
            check(LQA.close(bounds(d.state, child), b0.offsetBy(dx: 30, dy: 20), 0.01), "Free Transform moves a layer selected together with its group once", LQA.fmt(bounds(d.state, child)))
        }
        LQA.withDoc(st, select: both) { d in
            let g0 = bounds(d.state, ids[0])
            AppActions.flipLayers(horizontal: true)
            let g1 = bounds(d.state, ids[0])
            check(LQA.close(g0, g1, 0.6), "Flip Horizontal flips a group + selected child once (the group stays in its box)", "\(LQA.fmt(g0)) → \(LQA.fmt(g1))")
            AppActions.align(.left)
            check(abs(bounds(d.state, ids[0]).minX) <= 1, "Align Left moves a group + selected child once", LQA.fmt(bounds(d.state, ids[0])))
        }
        let oldTool = AppModel.shared.tool
        AppModel.shared.tool = .move
        defer { AppModel.shared.tool = oldTool }
        LQA.withDoc(st, select: both) { d in
            AppActions.nudge(dx: 10, dy: 0)
            check(LQA.close(bounds(d.state, child), b0.offsetBy(dx: 10, dy: 0), 0.01), "nudging a group + selected child moves the child once", LQA.fmt(bounds(d.state, child)))
        }
        // linked layers
        (st, ids) = make("linked.pair")
        let other = st.layers.last!.id
        let o0 = bounds(st, other)
        LQA.withDoc(st, select: ids) { d in
            AppActions.nudge(dx: 7, dy: -3)
            check(LQA.close(bounds(d.state, other), o0.offsetBy(dx: 7, dy: -3), 0.01), "nudging a layer moves the layers linked to it", LQA.fmt(bounds(d.state, other)))
        }
        LQA.withDoc(st, select: ids) { d in
            let u0 = QATransforms.unionBounds(d.state, [ids[0], other])!
            AppActions.rotateLayers(degrees: 180)
            let u1 = QATransforms.unionBounds(d.state, [ids[0], other])!
            check(LQA.close(u0, u1, 1) && !LQA.close(bounds(d.state, other), o0, 5), "Rotate 180° turns linked layers together", "\(LQA.fmt(u0)) → \(LQA.fmt(u1))")
        }
        // position lock
        (st, ids) = make("lock.position.shape")
        LQA.withDoc(st, select: ids) { d in
            AppActions.align(.left)
            check(bounds(d.state, ids[0]) == bounds(st, ids[0]), "Align leaves a position-locked layer alone")
        }
    }

    // MARK: Frame animation: edits that are more than a move

    static func animationFrames() {
        TimelineController.install()
        func frames(_ name: String, _ what: String, op: @escaping (Document, UUID) -> Void) {
            let (st0, ids) = make(name)
            let id = ids[0]
            var stB = st0
            stB.updateLayer(id) { $0.translate(dx: 60, dy: 40) }
            var st = st0
            st.frames = [Animation.capture(st0), Animation.capture(stB)]
            // expected frame 2: the same edit made while the layer sits at its frame-2 position
            let want = LQA.withDoc(stB, select: ids) { d -> PixelBuffer in op(d, id); return LQA.render(d.state, blur: 1) }
            LQA.withDoc(st, select: ids) { d in
                TimelineController.shared.selection[d.id] = 0
                op(d, id)
                guard d.state.frames.count == 2 else { check(false, what, "frames lost"); return }
                let got = LQA.render(Animation.applied(d.state.frames[1], to: d.state), blur: 1)
                let df = LQA.diff(want, got)
                let ok = df.within(mean: 1.0, bad: 0.006)
                if !ok { LQA.dumpPair(want, got, "regress_frames_\(name)") }
                check(ok, what, df.description)
                TimelineController.shared.selection[d.id] = nil
            }
        }
        let scale: (Document, UUID) -> Void = { d, id in
            guard let b = QATransforms.unionBounds(d.state, [id]) else { return }
            QATransforms.apply(QATransforms.around(b.origin, CGAffineTransform(scaleX: 1.6, y: 1.6)), doc: d, ids: [id])
        }
        frames("text.point", "frame animation: scaling a type layer in one frame keeps its place in the other frames", op: scale)
        frames("shape.rounded", "frame animation: scaling a shape in one frame keeps its place in the other frames", op: scale)
        frames("raster.small", "frame animation: scaling a pixel layer in one frame keeps its place in the other frames", op: scale)
        frames("smart.image", "frame animation: flipping a smart object in one frame keeps its place in the other frames") { _, _ in AppActions.flipLayers(horizontal: true) }
        frames("text.point", "frame animation: rasterizing a type layer keeps its place in the other frames") { _, id in AppActions.rasterizeLayer(id) }
        frames("text.point", "frame animation: converting type to a shape keeps its place in the other frames") { _, _ in AppActions.convertTextToShape() }
        frames("raster.small", "frame animation: painting on a small layer (its buffer grows to the canvas) keeps its place in the other frames") { d, id in
            guard let (buf, o) = d.beginPixelEdit(layerID: id, target: .content) else { return }
            buf.context.setFillColor(RGBA.black.cgColor)
            buf.context.fill(CGRect(x: 100 - o.x, y: 90 - o.y, width: 12, height: 12))
            buf.markDirty()
            d.commit("Brush")
        }
        // a plain move stays a per-frame edit
        let (st0, ids) = make("text.point")
        var stB = st0
        stB.updateLayer(ids[0]) { $0.translate(dx: 60, dy: 40) }
        var st = st0
        st.frames = [Animation.capture(st0), Animation.capture(stB)]
        LQA.withDoc(st, select: ids) { d in
            TimelineController.shared.selection[d.id] = 0
            d.updateLayer(ids[0]) { $0.translate(dx: -25, dy: 10) }
            d.commit("Move")
            same(stB, Animation.applied(d.state.frames[1], to: d.state), "frame animation: moving a layer in one frame leaves the other frames alone")
            TimelineController.shared.selection[d.id] = nil
        }
    }

    // MARK: A document that uses everything: .lumen round trip

    static func richDocumentRoundTrip() {
        var st = QASubjects.base()
        for name in ["text.warp.arc", "shape.path.boolean", "smart.warp", "group.nested", "artboard", "frame.image", "generative", "fx.multi.smart", "mask.feather.shape", "clip.base"] {
            let (s, _) = make(name)
            for l in s.layers where l.name != "Background" && l.name != "Under" { st.layers.append(l) }
            st.generative.merge(s.generative) { a, _ in a }
            st.toolData.frames += s.toolData.frames
        }
        QALayerCommands.rectSelection(&st)
        st.alphaChannels = [AlphaChannel(name: "Alpha 1", buffer: st.selection!.copy())]
        st.paths = [NamedPath(name: "Path 1", path: VectorPath.ellipse(CGRect(x: 40, y: 40, width: 100, height: 60)))]
        st.guides = [Guide(isVertical: true, position: 120), Guide(isVertical: false, position: 77.5)]
        st.globalLight = GlobalLight(angle: 33, altitude: 45)
        st.toolData.slices = [DocSlice(rect: CGRect(x: 10, y: 10, width: 50, height: 40), name: "slice")]
        st.toolData.colorSamplers = [CGPoint(x: 5, y: 6)]
        st.frames = [Animation.capture(st)]
        var second = Animation.capture(st); second.id = UUID(); second.delay = 0.5
        st.frames.append(second)
        st.layerComps = [LQA.withDoc(st) { _ in AppActions.captureComp(name: "Comp") }]
        var tl = VideoTimeline(duration: 3, frameRate: 24)
        var tr = LayerTrack(layerID: st.layers.last!.id, duration: 3)
        tr.setKeys(.position, [Keyframe(time: 0, value: .point(CGPoint(x: 10, y: 20))), Keyframe(time: 2, interpolation: .ease, value: .point(CGPoint(x: 200, y: 120)))])
        tr.setKeys(.opacity, [Keyframe(time: 0, value: .number(0.2)), Keyframe(time: 1, value: .number(1))])
        tl.tracks = [tr]
        st.videoTimeline = tl
        let url = LQA.out.appendingPathComponent("qa_regress_rich.imagecrat")
        do {
            try DocumentIO.saveNative(Document(state: st, name: "rich"), to: url)
            let back = try DocumentIO.load(url: url).state
            check(LQA.Snapshot(back).matches(LQA.Snapshot(st)), ".imagecrat round trip of a document with every layer kind, frames, comps, timeline and tool data is lossless")
            check(back.videoTimeline == st.videoTimeline && back.toolData.slices == st.toolData.slices && back.toolData.frames == st.toolData.frames
                  && Set(back.generative.keys) == Set(st.generative.keys) && back.guides == st.guides && back.paths == st.paths && back.globalLight == st.globalLight,
                  ".imagecrat keeps timeline, slices, frame-tool data, generative metadata, guides, paths and Global Light")
            let df = LQA.diff(LQA.render(st), LQA.render(back))
            check(df.maxv <= 1, ".imagecrat round trip renders identically", df.description)
            // second generation is byte-stable in content
            try DocumentIO.saveNative(Document(state: back, name: "rich"), to: url)
            let again = try DocumentIO.load(url: url).state
            check(LQA.Snapshot(again).matches(LQA.Snapshot(back)), ".imagecrat re-save of a loaded document is identical")
        } catch { check(false, ".imagecrat round trip of a rich document", "\(error)") }
    }
}
