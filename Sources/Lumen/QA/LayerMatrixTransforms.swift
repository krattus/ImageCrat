import AppKit
import CoreImage
import ImageCratCore

/// A pre-transform applied through the same code path as Edit ▸ Free Transform.
struct QAXF {
    var name: String
    /// Translation / rotation / mirror: nothing is resampled to a different size.
    var rigid: Bool
    var make: (CGRect) -> Homography
    var isAffine: Bool { name != "perspective" }
    var isTranslate: Bool { name == "translate" }
}

enum QATransforms {
    static func around(_ c: CGPoint, _ t: CGAffineTransform) -> Homography {
        Homography(affine: CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(t).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
    }

    static let all: [QAXF] = [
        QAXF(name: "translate", rigid: true) { _ in Homography(affine: CGAffineTransform(translationX: 37, y: -23)) },
        QAXF(name: "scale2.2", rigid: false) { b in around(b.origin, CGAffineTransform(scaleX: 2.2, y: 2.2)) },
        QAXF(name: "scale0.4", rigid: false) { b in around(b.center, CGAffineTransform(scaleX: 0.4, y: 0.4)) },
        QAXF(name: "nonuniform", rigid: false) { b in around(b.center, CGAffineTransform(scaleX: 1.5, y: 0.6)) },
        QAXF(name: "rotate33", rigid: true) { b in around(b.center, CGAffineTransform(rotationAngle: 33 * .pi / 180)) },
        QAXF(name: "skew", rigid: false) { b in around(b.center, CGAffineTransform(a: 1, b: 0, c: 0.35, d: 1, tx: 0, ty: 0)) },
        QAXF(name: "flipH", rigid: true) { b in around(b.center, CGAffineTransform(scaleX: -1, y: 1)) },
        QAXF(name: "flipV", rigid: true) { b in around(b.center, CGAffineTransform(scaleX: 1, y: -1)) },
        QAXF(name: "perspective", rigid: false) { b in
            let q = Quad(tl: CGPoint(x: b.minX + b.width * 0.12, y: b.minY + b.height * 0.08), tr: CGPoint(x: b.maxX - b.width * 0.05, y: b.minY + b.height * 0.2),
                         br: CGPoint(x: b.maxX, y: b.maxY), bl: CGPoint(x: b.minX + b.width * 0.03, y: b.maxY - b.height * 0.12))
            return Homography(from: Quad(rect: b), to: q) ?? .identity
        },
    ]

    static func named(_ n: String) -> QAXF { all.first { $0.name == n }! }

    static func unionBounds(_ st: DocumentState, _ ids: [UUID]) -> CGRect? {
        var u: CGRect? = nil
        for id in ids { if let l = st.layer(id), let b = Compositor.shared.contentBounds(l, state: st) { u = u.map { $0.union(b) } ?? b } }
        return u
    }

    /// Edit ▸ Free Transform: start a session on the layers (plus linked ones), move the quad, confirm.
    @discardableResult
    static func apply(_ h: Homography, doc d: Document, ids: [UUID]) -> Bool {
        guard let s = TransformSession(doc: d, layerIDs: d.withLinked(ids)) else { return false }
        s.quad = s.sourceQuad.mapped(h.apply)
        s.updatePreview()
        s.commit()
        return true
    }

    /// Edit ▸ Transform ▸ Warp with a preset, confirmed.
    @discardableResult
    static func warp(doc d: Document, id: UUID, style: WarpStyle = .arc, bend: Double = 0.5) -> Bool {
        guard let s = WarpSession(doc: d, layerID: id) else { return false }
        s.style = style
        s.bend = bend
        s.commit()
        return true
    }

    /// Subject state after a pre-transform (nil name = untouched; "warp" = warp preset). Returns nil when it does not apply.
    static func prepared(_ subj: QASubject, _ xf: String?) -> (DocumentState, [UUID])? {
        let (st, ids) = subj.make()
        guard let xf else { return (st, ids) }
        return LQA.withDoc(st, select: ids) { d -> (DocumentState, [UUID])? in
            if xf == "warp" {
                guard ids.count == 1, let l = d.state.layer(ids[0]), WarpApply.canWarp(l), !l.locks.positionLocked else { return nil }
                guard warp(doc: d, id: ids[0]) else { return nil }
                return (d.state, ids)
            }
            guard let b = unionBounds(d.state, d.withLinked(ids)) else { return nil }
            guard apply(named(xf).make(b), doc: d, ids: ids) else { return nil }
            return (d.state, ids)
        }
    }

    // MARK: Twin (rasterized reference)

    /// The same layer with its content replaced by pixels (attributes, masks and effects untouched).
    static func twin(_ l: Layer, _ st: DocumentState) -> Layer {
        var t = l
        switch l.content {
        case .text, .shape, .smartObject:
            let sp = LQA.space(st)
            guard let img = Compositor.shared.contentImage(l, space: sp) else { return l }
            let r = LQA.contentArea(st)
            let buf = RenderEngine.renderBuffer(img, docRect: r, space: sp)
            guard let ob = LQA.opaqueBounds(buf, threshold: 0) else { return l }
            t.content = .raster(RasterContent(buffer: buf.cropped(to: ob), origin: IPoint(x: r.x + ob.x, y: r.y + ob.y)))
        case .group(var g):
            g.children = g.children.map { twin($0, st) }
            t.content = .group(g)
        default: break
        }
        return t
    }

    /// Twin whose linked layer mask / vector mask is baked into the pixels: an independent reference for "masks
    /// follow the layer" (the plain twin would transform its mask with the very code under test).
    /// Returns nil when baking does not apply (no mask, unlinked mask, content outside the canvas).
    static func bakedTwin(_ l: Layer, _ st: DocumentState, keepBounds: Bool = false) -> Layer? {
        guard l.mask != nil || l.vectorMask != nil, l.mask?.isLinked ?? true, !l.isGroup, !l.isFill, !l.isAdjustment else { return nil }
        guard let cb = Compositor.shared.contentBounds(l, state: st), st.canvasCGRect.contains(cb) else { return nil }
        var tmp = l
        tmp.effects = LayerEffects(); tmp.opacity = 1; tmp.fillOpacity = 1; tmp.blendMode = .normal; tmp.isClipped = false; tmp.blendIf = BlendIf(); tmp.knockout = .none
        tmp.channelR = true; tmp.channelG = true; tmp.channelB = true; tmp.isVisible = true
        let buf = LQA.renderLayer(tmp, st)
        if keepBounds {
            // keep the box of the unmasked content: two barely visible corner pixels
            let r = IRect(enclosing: cb).intersection(st.canvasRect)
            let p = buf.data.assumingMemoryBound(to: UInt8.self)
            for (x, y) in [(r.minX, r.minY), (r.maxX - 1, r.maxY - 1)] where x >= 0 && y >= 0 && x < buf.width && y < buf.height {
                let o = y * buf.bytesPerRow + x * 4
                if p[o + 3] == 0 { p[o + 3] = 1 }
            }
            buf.markDirty()
        }
        var t = l
        t.content = .raster(RasterContent(buffer: buf, origin: .zero))
        t.mask = nil; t.vectorMask = nil
        return t
    }

    static func twinApplies(_ subj: QASubject, _ xf: QAXF, _ layers: [Layer]) -> Bool {
        if subj.has("pattern") || subj.has("canvasFill") || subj.has("noContent") { return false }
        if subj.has("gradient") && !(xf.isTranslate || xf.name.hasPrefix("scale")) { return false }   // gradient angle is relative to the new bounds
        if subj.has("stroke") && !xf.rigid { return false }                                           // stroke width is not scaled
        if subj.has("filters") && !xf.isTranslate { return false }                                    // smart filters run after the transform
        if !xf.isAffine && layers.contains(where: { $0.allLeaves.contains { $0.isText } }) { return false }   // type cannot take perspective
        if subj.has("fx") && !xf.rigid && subj.has("stroke") { return false }
        return true
    }

    // MARK: Geometry invariants

    /// contentBounds (what handles / align / smart-object conversion use) against the pixels the layer really draws.
    static func checkGeometry(_ l: Layer, _ st: DocumentState, subject: QASubject, label: String, check name: String) {
        if case .group(let g) = l.content {
            if g.artboard != nil {
                if let cb = Compositor.shared.contentBounds(l, state: st), let ab = LQA.alphaBounds(l, st) {
                    let vis = LQA.visibleArea(st)
                    LQA.check(LQA.encloses(cb, ab.intersection(vis), 2), name, label, "artboard bounds \(LQA.fmt(cb)) do not enclose what is drawn \(LQA.fmt(ab))")
                }
                return
            }
            for c in g.children { checkGeometry(c, st, subject: subject, label: label + "/" + c.name, check: name) }
            return
        }
        let cb = Compositor.shared.contentBounds(l, state: st)
        if l.isAdjustment { LQA.check(cb == nil, name, label, "adjustment layer reports bounds"); return }
        guard let cb else { LQA.check(false, name, label, "no content bounds"); return }
        guard LQA.finite(cb), cb.width > 0, cb.height > 0 else { LQA.check(false, name, label, "degenerate bounds \(LQA.fmt(cb))"); return }
        if l.isFill { LQA.check(cb == st.canvasCGRect, name, label, "fill layer bounds \(LQA.fmt(cb))"); return }
        guard let ab = LQA.alphaBounds(l, st) else {
            // nothing visible: acceptable only if the layer is entirely off the rendered area
            let reach = st.canvasCGRect.insetBy(dx: -60, dy: -60)
            LQA.check(!cb.intersects(reach), name, label, "layer draws nothing but reports bounds \(LQA.fmt(cb))")
            return
        }
        let vis = LQA.visibleArea(st)
        let cv = cb.intersection(vis), av = ab.intersection(vis)
        if cv.isNull || av.isNull || cv.isEmpty || av.isEmpty {
            LQA.check(cv.isEmpty == av.isEmpty || cv.width < 3 || cv.height < 3 || av.width < 3 || av.height < 3, name, label, "bounds \(LQA.fmt(cb)) vs drawn \(LQA.fmt(ab))")
            return
        }
        let loose = l.isText || subject.has("loose") && !(l.isRaster || l.isSmartObject)
        if loose {
            let tol = max(4, 0.15 * min(cb.width, cb.height))
            let okEnclose = LQA.encloses(cv, av, tol)
            let inside = vis.contains(cb)
            let okSize = !inside || (av.width >= cv.width * 0.25 && av.height >= cv.height * 0.12)
            LQA.check(okEnclose && okSize, name, label, "bounds \(LQA.fmt(cb)) vs drawn \(LQA.fmt(ab))")
        } else if l.isSmartObject, l.smart?.filters.isEmpty == false {
            LQA.check(LQA.encloses(cv.insetBy(dx: -40, dy: -40), av, 0) && LQA.encloses(av, cv.insetBy(dx: 6, dy: 6), 0), name, label, "bounds \(LQA.fmt(cb)) vs drawn \(LQA.fmt(ab))")
        } else if l.smart?.warp != nil {
            LQA.check(LQA.close(cv, av, 3), name, label, "bounds \(LQA.fmt(cb)) vs drawn \(LQA.fmt(ab))")
        } else if let sh = l.shape, !sh.stroke.paint.isNone, sh.stroke.alignment != .inside {
            // mitred corners of a centred / outside stroke reach past the nominal stroke width
            let m = CGFloat(sh.stroke.width) * 1.2 + 2
            LQA.check(LQA.encloses(cv.insetBy(dx: -m, dy: -m), av, 0) && LQA.encloses(av, cv, 2), name, label, "bounds \(LQA.fmt(cb)) vs drawn \(LQA.fmt(ab))")
        } else {
            LQA.check(LQA.close(cv, av, 2), name, label, "bounds \(LQA.fmt(cb)) vs drawn \(LQA.fmt(ab))")
        }
    }

    /// The Free Transform box a new session would show for the layer.
    static func sessionQuad(_ d: Document, _ ids: [UUID]) -> Quad? {
        guard let s = TransformSession(doc: d, layerIDs: ids) else { return nil }
        let q = s.sourceQuad
        s.cancel()
        return q
    }

    static func quadClose(_ a: Quad, _ b: Quad, _ tol: CGFloat) -> Bool {
        zip(a.points, b.points).allSatisfy { $0.distance(to: $1) <= tol }
    }

    // MARK: Matrix 1 — every subject × every transform

    static func runMatrix(_ subjects: [QASubject]) {
        for subj in subjects {
            let few = LQA.full ? ["translate", "scale2.2", "rotate33", "perspective"] : ["scale2.2", "perspective"]
            let xfs: [QAXF] = subj.core ? all : all.filter { few.contains($0.name) }
            for xf in xfs {
                if let f = LQA.cmdFilter, !xf.name.contains(f) { continue }
                runOne(subj, xf)
            }
            Compositor.shared.clearCaches()
        }
    }

    static func runOne(_ subj: QASubject, _ xf: QAXF) {
        if subj.has("artboard"), ["rotate33", "skew", "perspective"].contains(xf.name) {
            LQA.note("artboards only move and resize (Photoshop does not rotate / skew artboards); rotate, skew and perspective are skipped for them")
            return
        }
        let (st0, ids) = subj.make()
        let label = "\(subj.name) × \(xf.name)"
        let G = "m1.transform"
        LQA.withDoc(st0, select: ids) { d in
            let all = d.withLinked(ids)
            let snap0 = LQA.Snapshot(d.state)
            let before = all.compactMap { d.state.layer($0) }
            // untransformed geometry must already be consistent
            if xf.isTranslate { for l in before { checkGeometry(l, d.state, subject: subj, label: subj.name + " (untouched)", check: "\(G): bounds match the drawn pixels") } }
            guard let b = unionBounds(d.state, all) else {
                LQA.check(before.allSatisfy { $0.isAdjustment || $0.locks.positionLocked }, "\(G): session starts", label, "no bounds")
                return
            }
            let h = xf.make(b)
            let quad0 = sessionQuad(d, all)
            LQA.check(d.contentOverrides.isEmpty && LQA.Snapshot(d.state).matches(snap0), "\(G): cancelled session leaves the document untouched", label)
            let histBefore = d.history.count

            // reference: the same transform applied to a rasterized twin of the subject
            var refImage: PixelBuffer? = nil
            if twinApplies(subj, xf, before) {
                var tst = d.state
                for l in before {
                    // masks: feather is a setting (not scaled), so a baked reference only holds for rigid transforms
                    let bake = (l.mask?.feather ?? 0) == 0 || xf.rigid
                    let t = (bake ? bakedTwin(l, d.state) : nil) ?? twin(l, d.state)
                    tst.updateLayer(l.id) { $0 = t }
                }
                refImage = LQA.withDoc(tst, select: ids) { td -> PixelBuffer? in
                    guard apply(h, doc: td, ids: ids) else { return nil }
                    return LQA.render(td.state, blur: 2.5)
                }
            }

            let started = apply(h, doc: d, ids: ids)
            if before.allSatisfy({ $0.locks.positionLocked }) {
                LQA.check(!started && LQA.Snapshot(d.state).matches(snap0), "\(G): position-locked layers cannot be transformed", label)
                return
            }
            guard started else { LQA.check(false, "\(G): session starts", label); return }
            LQA.check(d.contentOverrides.isEmpty && d.displayOverride == nil && d.hiddenLayers.isEmpty, "\(G): no preview override left behind", label)
            LQA.check(d.history.count == histBefore + 1, "\(G): one history step", label, "\(histBefore) → \(d.history.count)")
            LQA.check(LQA.canon(d.state) != nil, "\(G): finite geometry", label, "state no longer encodes (NaN / infinity)")
            let after = all.compactMap { d.state.layer($0) }
            LQA.check(after.count == before.count, "\(G): layers kept", label)

            for (l0, l1) in zip(before, after) {
                // attributes & editability
                let ad = LQA.attrDiff(LQA.attrs(l0), LQA.attrs(l1))
                LQA.check(ad.isEmpty, "\(G): attributes preserved", label, ad.joined(separator: "; "))
                LQA.check(LQA.kind(l0) == LQA.kind(l1), "\(G): layer kind preserved", label, "\(LQA.kind(l0)) → \(LQA.kind(l1))")
                switch (l0.content, l1.content) {
                case (.text(let a), .text(let c)):
                    var a2 = a; a2.transform = c.transform
                    LQA.check(a2 == c, "\(G): text stays editable (only its transform changes)", label)
                    if xf.isAffine {
                        let expected = TextRenderer.docQuad(a).mapped(h.apply)
                        LQA.check(quadClose(expected, TextRenderer.docQuad(c), 0.05), "\(G): text box follows the transform", label)
                    }
                case (.shape(let a), .shape(let c)):
                    LQA.check(a.geometry == c.geometry && a.fill == c.fill && a.stroke == c.stroke, "\(G): shape stays live (geometry parameters kept)", label)
                    let exp = a.path.mapped(h.apply).bounds
                    LQA.check(LQA.close(exp, c.path.bounds, 0.05), "\(G): shape path follows the transform", label, "\(LQA.fmt(exp)) vs \(LQA.fmt(c.path.bounds))")
                case (.smartObject(let a), .smartObject(let c)):
                    LQA.check(a.filters == c.filters && a.sourceRevision == c.sourceRevision && a.stackMode == c.stackMode && a.linkedURL == c.linkedURL
                             && (a.warp == nil) == (c.warp == nil), "\(G): smart object keeps source, filters and warp", label)
                    LQA.check(quadClose(a.quad.mapped(h.apply), c.quad, 0.01), "\(G): smart object quad follows the transform", label)
                default: break
                }
                if let m0 = l0.mask, let m1 = l1.mask, !m0.isLinked {
                    LQA.check(m0.origin == m1.origin && m0.buffer === m1.buffer, "\(G): unlinked mask stays put", label)
                }
                checkGeometry(l1, d.state, subject: subj, label: label, check: "\(G): bounds match the drawn pixels")
            }

            // the next transform box must sit on the transformed content
            if let q0 = quad0, let q1 = sessionQuad(d, all) {
                if before.count == 1, before[0].isSmartObject || before[0].isText, xf.isAffine || before[0].isSmartObject, before[0].smart?.warp == nil {
                    LQA.check(quadClose(q0.mapped(h.apply), q1, 0.05), "\(G): transform box follows the content", label)
                } else if let ub = unionBounds(d.state, all) {
                    LQA.check(LQA.close(q1.bounds, ub, 0.5), "\(G): transform box equals the content bounds", label, "\(LQA.fmt(q1.bounds)) vs \(LQA.fmt(ub))")
                }
            }

            // appearance against the rasterized twin
            if let ref = refImage {
                let got = LQA.render(d.state, blur: 2.5)
                let df = LQA.diff(got, ref, threshold: 40)
                let ok = df.within(mean: 2.2, bad: 0.012)
                if !ok { LQA.dumpPair(got, ref, "m1_" + label) }
                LQA.check(ok, "\(G): result looks like the transformed pixels", label, df.description)
            }

            // undo / redo
            let snap1 = LQA.Snapshot(d.state)
            d.undo()
            LQA.check(LQA.Snapshot(d.state).matches(snap0), "\(G): undo restores the previous state", label)
            d.redo()
            LQA.check(LQA.Snapshot(d.state).matches(snap1), "\(G): redo reproduces the result", label)

            // T then T⁻¹
            if let inv = h.inverted, let orig = Optional(LQA.render(st0, blur: 2.5)) {
                if apply(inv, doc: d, ids: ids) {
                    let back = LQA.render(d.state, blur: 2.5)
                    let df = LQA.diff(back, orig, threshold: 40)
                    let rasterish = before.contains { $0.allLeaves.contains { $0.isRaster } }
                    let ok = rasterish ? df.within(mean: 2.5, bad: 0.02) : df.within(mean: 0.8, bad: 0.004)
                    let textPerspective = !xf.isAffine && before.contains { $0.allLeaves.contains { $0.isText } }
                    if textPerspective { LQA.note("type layers approximate perspective by an affine transform (Photoshop disables Distort / Perspective for type)") }
                    else {
                        if !ok { LQA.dumpPair(back, orig, "m1_inverse_" + label) }
                        LQA.check(ok, "\(G): transform then inverse restores the appearance", label, df.description)
                    }
                    for (l0, id) in zip(before, all) where !textPerspective {
                        guard let l2 = d.state.layer(id) else { continue }
                        if let a = l0.text, let c = l2.text { LQA.check(quadClose(TextRenderer.docQuad(a), TextRenderer.docQuad(c), 0.05), "\(G): transform then inverse restores vector geometry", label) }
                        if let a = l0.smart, let c = l2.smart { LQA.check(quadClose(a.quad, c.quad, 0.01), "\(G): transform then inverse restores vector geometry", label) }
                        if let a = l0.shape, let c = l2.shape { LQA.check(LQA.close(a.path.bounds, c.path.bounds, 0.05), "\(G): transform then inverse restores vector geometry", label) }
                    }
                }
            }
        }
    }
}

extension Layer {
    /// Non-group layers of the subtree.
    var allLeaves: [Layer] { isGroup ? children.flatMap { $0.allLeaves } : [self] }
}
