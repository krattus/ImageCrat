import AppKit
import CoreImage
import ImageCratCore

/// One command run on one prepared subject.
final class QACtx {
    let subj: QASubject
    let xf: String?
    let d: Document
    let ids: [UUID]
    let st0: DocumentState
    let label: String
    var group = ""
    /// Scratch values passed from `run` to `verify`.
    var notes: [String: Any] = [:]

    init(_ subj: QASubject, _ xf: String?, _ d: Document, _ ids: [UUID]) {
        self.subj = subj; self.xf = xf; self.d = d; self.ids = ids; st0 = d.state
        label = subj.name + (xf.map { " [\($0)]" } ?? "")
    }

    lazy var img0: PixelBuffer = LQA.render(st0)
    var id: UUID { ids.last! }
    var layer0: Layer { st0.layer(id)! }
    var layer: Layer? { d.state.layer(id) }
    var active: Layer? { d.activeLayer }

    func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") { LQA.check(ok, "\(group): \(what)", label, detail()) }

    /// The document must look the same as before the command.
    func sameAppearance(_ what: String = "appearance preserved", mean: Double = 0.6, bad: Double = 0.004, of st: DocumentState? = nil, to ref: PixelBuffer? = nil) {
        let got = LQA.render(st ?? d.state)
        let df = LQA.diff(got, ref ?? img0)
        let ok = df.within(mean: mean, bad: bad)
        if !ok { LQA.dumpPair(ref ?? img0, got, "\(group)_\(label)") }
        check(ok, what, df.description)
    }

    func attrsKept(_ a: Layer, _ b: Layer, ignoring: Set<String> = [], _ what: String = "attributes preserved") {
        let ad = LQA.attrDiff(LQA.attrs(a), LQA.attrs(b), ignoring: ignoring)
        check(ad.isEmpty, what, ad.joined(separator: "; "))
    }
}

struct QACmd {
    var name: String
    /// Key commands run on every pre-transform variant; the others on the untouched subject (and scale ×2.2 for core subjects).
    var key = false
    /// Also run on attribute subjects (masks, effects, blending, locks …).
    var attrs = true
    var steps = 1
    /// Command replaces the whole layer stack (merge visible, flatten).
    var replacesStack = false
    /// Run `verify` even when the command left the document untouched (commands that act on another document).
    var alwaysVerify = false
    /// Default run: only on a small set of representative subjects (the full matrix runs it everywhere).
    var subset = false
    var prepare: ((inout DocumentState, [UUID]) -> Void)? = nil
    var applies: (QACtx) -> Bool = { _ in true }
    var run: (QACtx) -> Void
    var verify: (QACtx) -> Void = { _ in }
}

enum QALayerCommands {
    static let selRect = CGRect(x: 110, y: 85, width: 90, height: 70)

    static func rectSelection(_ st: inout DocumentState, _ r: CGRect = selRect) {
        let b = PixelBuffer(width: st.width, height: st.height, format: .gray)
        b.context.setFillColor(gray: 1, alpha: 1)
        b.context.fill(r)
        b.markDirty()
        st.selection = b
    }

    static func isLocked(_ c: QACtx) -> Bool { c.ids.allSatisfy { c.st0.layer($0)?.locks.positionLocked == true } }
    static func hasBounds(_ c: QACtx) -> Bool { QATransforms.unionBounds(c.st0, c.ids) != nil }
    static func single(_ c: QACtx) -> Bool { c.ids.count == 1 }

    /// Layer content (no mask / effects) over the content area, for pixel comparisons.
    static func content(_ l: Layer, _ st: DocumentState, mask: PixelBuffer? = nil) -> PixelBuffer? {
        let sp = LQA.space(st)
        guard var img = Compositor.shared.contentImage(l, space: sp) else { return nil }
        if let m = mask { img = img.masked(byGray: m.ciImage.composited(over: CIImage.color(.black, img.extent.union(sp.ciCanvas).insetBy(dx: -200, dy: -200)))) }
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
    }

    // MARK: Runner

    static func runMatrix(_ subjects: [QASubject]) {
        let cmds = commands().filter { c in LQA.cmdFilter.map { c.name.lowercased().contains($0.lowercased()) } ?? true }
        let previousPasteboard = AppActions.pasteboard
        let pb = NSPasteboard(name: NSPasteboard.Name("lumen.qa.\(ProcessInfo.processInfo.processIdentifier)"))
        AppActions.pasteboard = pb        // never touch the user's clipboard
        defer { AppActions.pasteboard = previousPasteboard; pb.releaseGlobally(); AppActions.clipboard = nil; AppActions.copiedEffects = nil }
        for subj in subjects {
            let variants: [String?] = subj.core ? [nil, "scale2.2", "rotate33", "perspective", "warp"] : [nil, "scale2.2"]
            for (vi, v) in variants.enumerated() {
                let wanted = cmds.filter { cmd in
                    if !subj.core && !cmd.attrs { return false }
                    if vi == 0 { return true }
                    if LQA.full { return cmd.key || (vi == 1 && subj.core) }
                    // default run: the key conversions on scaled / distorted layers, the central three on rotated / warped ones
                    guard cmd.key, subj.core else { return false }
                    return vi == 1 || vi == 3 || ["Convert to Smart Object", "Rasterize Layer", "Merge Down"].contains(cmd.name)
                }
                if !LQA.full && !subj.core && vi > 0 { continue }
                guard let (st, ids) = QATransforms.prepared(subj, v) else { continue }
                for cmd in wanted { runOne(cmd, subj, v, st, ids) }
                if LQA.wants("m2.files") {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    fileRoundTrips(subj, v, st, ids)
                    timing["(file round trips)", default: 0] += CFAbsoluteTimeGetCurrent() - t0
                }
            }
            Compositor.shared.clearCaches()
        }
    }

    static func printTiming() {
        guard LQA.env["LUMEN_QA_TIMING"] == "1" else { return }
        for (k, v) in timing.sorted(by: { $0.value > $1.value }) { print(String(format: "timing %6.1f s  %@", v, k)) }
    }

    static var timing: [String: Double] = [:]

    static func runOne(_ cmd: QACmd, _ subj: QASubject, _ xf: String?, _ state: DocumentState, _ ids: [UUID], group: String = "m2.layer") {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timing[cmd.name, default: 0] += CFAbsoluteTimeGetCurrent() - t0 }
        var st = state
        cmd.prepare?(&st, ids)
        LQA.withDoc(st, select: ids) { d in
            let c = QACtx(subj, xf, d, ids)
            c.group = "\(group): \(cmd.name)"
            guard cmd.applies(c) else { return }
            let snap0 = LQA.Snapshot(d.state)
            let h0 = d.history.count
            let subjectIDs = Set(ids.flatMap { d.state.layer($0)?.allIDs ?? [] })
            let others = Set(d.state.allLayers.map(\.id)).subtracting(subjectIDs)
            cmd.run(c)
            c.check(d.contentOverrides.isEmpty && d.displayOverride == nil && d.hiddenLayers.isEmpty, "no preview override left behind")
            let snap1 = LQA.Snapshot(d.state)
            c.check(snap1.data != nil, "finite geometry", "state no longer encodes (NaN / infinity)")
            let delta = d.history.count - h0
            if delta == 0 {
                c.check(snap1.matches(snap0), "no uncommitted change", "the document changed without a history step")
            } else {
                c.check(delta == cmd.steps, "one history step per command", "\(delta) steps")
            }
            if !cmd.replacesStack {
                let now = Set(d.state.allLayers.map(\.id))
                c.check(others.isSubset(of: now), "other layers kept", "\(others.subtracting(now).count) layer(s) dropped")
            }
            c.check(d.activeLayerID.map { d.state.layer($0) != nil } ?? d.state.layers.isEmpty, "active layer valid")
            if delta > 0 || cmd.alwaysVerify || !snap1.matches(snap0) { cmd.verify(c) }
            c.check(LQA.Snapshot(d.state).matches(snap1), "verification left the document alone")
            for _ in 0..<delta { d.undo() }
            c.check(LQA.Snapshot(d.state).matches(snap0), "undo restores the previous state")
            for _ in 0..<delta { d.redo() }
            c.check(LQA.Snapshot(d.state).matches(snap1), "redo reproduces the result")
        }
    }

    // MARK: Commands

    static func commands() -> [QACmd] {
        var cmds: [QACmd] = []

        // ---------- Convert to Smart Object
        cmds.append(QACmd(name: "Convert to Smart Object", key: true, applies: hasBounds, run: { _ in AppActions.convertToSmartObject() }, verify: { c in
            guard let so = c.active, so.isSmartObject else { c.check(false, "result is a smart object"); return }
            c.check(c.ids.allSatisfy { c.d.state.layer($0) == nil }, "source layers are inside the smart object")
            if c.ids.count == 1 {
                c.check(so.name == c.layer0.name, "name kept", "\(c.layer0.name) → \(so.name)")
                c.check(so.isClipped == c.layer0.isClipped, "clipping kept")
                c.check(so.isVisible == c.layer0.isVisible, "visibility kept")
                c.check(so.colorLabel == c.layer0.colorLabel && so.linkID == c.layer0.linkID, "colour label and link kept")
            }
            if c.subj.has("pattern") || c.subj.name.contains("patternOverlay") || c.subj.name == "fill.pattern" {
                LQA.note("pattern fills are anchored to the canvas origin, so a pattern-filled layer shifts its pattern phase when it is nested in a smart object")
            } else if c.subj.has("blendfx") {
                LQA.note("effects with a blend mode (Multiply shadow, Screen glow …) end up inside the smart object and no longer blend with the layers below (as in Photoshop)")
            } else {
                c.sameAppearance()
            }
            if let cb = Compositor.shared.contentBounds(so, state: c.d.state), let ab = LQA.alphaBounds(so, c.d.state) {
                let vis = LQA.visibleArea(c.d.state)
                c.check(LQA.encloses(cb, ab.intersection(vis), 2), "smart object bounds enclose its pixels", "\(LQA.fmt(cb)) vs \(LQA.fmt(ab))")
            }
        }))

        // ---------- Rasterize
        cmds.append(QACmd(name: "Rasterize Layer", key: true, applies: { c in single(c) && !c.layer0.isRaster && !c.layer0.isAdjustment && !c.layer0.isGroup },
                          run: { c in AppActions.rasterizeLayer(c.id) }, verify: { c in
            guard let l = c.layer, l.isRaster else { c.check(false, "result is a pixel layer"); return }
            c.attrsKept(c.layer0, l)
            c.sameAppearance()
            QATransforms.checkGeometry(l, c.d.state, subject: c.subj, label: c.label, check: "\(c.group): bounds match the drawn pixels")
        }))

        cmds.append(QACmd(name: "Rasterize Layer Style", key: true, applies: { c in single(c) && !c.layer0.isAdjustment && !c.layer0.isGroup },
                          run: { _ in AppActions.rasterizeLayerStyle() }, verify: { c in
            guard let l = c.layer, l.isRaster else { c.check(false, "result is a pixel layer"); return }
            c.check(!l.effects.hasAny && l.mask == nil && l.vectorMask == nil && l.fillOpacity == 1, "style, fill opacity and masks are baked into the pixels")
            c.attrsKept(c.layer0, l, ignoring: ["effects", "fill", "mask", "vmask", "blendIf"])
            if c.subj.has("blendfx") {
                LQA.note("Rasterize Layer Style bakes effects that use a blend mode (shadows, glows, bevel) as normal pixels — the look changes as in Photoshop")
            } else if c.subj.has("knockout") || c.subj.name.hasPrefix("blendif") {
                LQA.note("Rasterize Layer Style: knockout / Blend If depend on the backdrop and are not baked")
            } else {
                c.sameAppearance(mean: 0.8, bad: 0.006)
            }
        }))

        // ---------- Duplicate
        cmds.append(QACmd(name: "Duplicate Layer", key: true, run: { _ in AppActions.duplicateLayers() }, verify: { c in
            guard let copy = c.active, let orig = c.layer else { c.check(false, "copy exists"); return }
            c.check(copy.id != orig.id && copy.name == orig.name + " copy", "copy is named “… copy”", copy.name)
            c.attrsKept(orig, copy, ignoring: ["name"])
            c.check(LQA.kind(orig) == LQA.kind(copy), "layer kind kept")
            let df = LQA.diff(LQA.renderLayer(orig, c.d.state), LQA.renderLayer(copy, c.d.state))
            c.check(df.within(mean: 0.05, bad: 0), "copy looks like the original", df.description)
            if let a = orig.raster, let b = copy.raster { c.check(a.buffer !== b.buffer, "pixels are copied, not shared") }
            if let a = orig.mask, let b = copy.mask { c.check(a.buffer !== b.buffer, "mask is copied, not shared") }
            // original hidden → the copy alone reproduces the document
            var st = c.d.state
            for id in c.ids { st.updateLayer(id) { $0.isVisible = false } }
            if !c.subj.has("hidden") { c.sameAppearance("copy replaces the hidden original", of: st) }
        }))

        // ---------- Layer via Copy / Cut (with a selection)
        for cut in [false, true] {
            cmds.append(QACmd(name: cut ? "Layer via Cut" : "Layer via Copy", prepare: { st, _ in rectSelection(&st) },
                              applies: { c in single(c) && !c.layer0.isAdjustment && !(cut && c.layer0.locks.pixelsLocked) },
                              run: { _ in AppActions.layerViaCopy(cut: cut) }, verify: { c in
                guard let nl = c.active, nl.id != c.id, nl.isRaster else { c.check(false, "new pixel layer"); return }
                guard let want = content(c.layer0, c.st0, mask: c.st0.selection), let got = content(nl, c.d.state) else { return }
                let df = LQA.diff(want, got)
                c.check(df.within(mean: 0.4, bad: 0.003), "new layer holds the selected pixels in place", df.description)
                if cut, c.layer0.isRaster, let src = c.layer, let inside = content(src, c.d.state, mask: c.st0.selection) {
                    c.check(LQA.opaqueBounds(inside, threshold: 2) == nil || c.layer0.locks.transparency, "cut pixels are removed from the source")
                }
            }))
        }

        // ---------- Delete
        cmds.append(QACmd(name: "Delete Layer", attrs: false, run: { _ in AppActions.deleteLayers() }, verify: { c in
            c.check(c.ids.allSatisfy { c.d.state.layer($0) == nil }, "layers removed")
        }))

        // ---------- Group / Ungroup
        // (artboards can't be grouped: Group Layers is disabled with an artboard selected, as in Photoshop — artboards3 checks the refusal)
        cmds.append(QACmd(name: "Group Layers", key: true, applies: { c in !c.ids.contains { c.st0.layer($0)?.isArtboard == true } }, run: { _ in AppActions.groupLayers() }, verify: { c in
            guard let g = c.active, g.isGroup else { c.check(false, "group created"); return }
            c.check(Set(g.children.map(\.id)) == Set(c.ids), "group holds the layers")
            for id in c.ids { if let a = c.st0.layer(id), let b = c.d.state.layer(id) { c.attrsKept(a, b, ignoring: ["clipped"], "grouped layers keep their attributes") } }
            if c.subj.name.hasPrefix("knockout.shallow") { LQA.note("a shallow knockout stops at the nearest group: grouping the layer changes what it reveals (as in Photoshop)") }
            else { c.sameAppearance() }
        }))
        cmds.append(QACmd(name: "Group then Ungroup", key: true, steps: 2, applies: { c in !c.ids.contains { c.st0.layer($0)?.isArtboard == true } }, run: { _ in AppActions.groupLayers(); AppActions.ungroupLayers() }, verify: { c in
            c.check(c.d.state.allLayers.map(\.id) == c.st0.allLayers.map(\.id), "layer order restored")
            for id in c.ids { if let a = c.st0.layer(id), let b = c.d.state.layer(id) { c.attrsKept(a, b, "attributes restored") } }
            c.sameAppearance()
        }))
        cmds.append(QACmd(name: "Ungroup Layers", applies: { c in single(c) && c.layer0.isGroup && !c.layer0.isArtboard }, run: { _ in AppActions.ungroupLayers() }, verify: { c in
            c.check(c.layer == nil, "group removed")
            let g = c.layer0
            c.check(g.children.allSatisfy { c.d.state.layer($0.id) != nil }, "children kept")
            if g.blendMode == .passThrough && g.opacity == 1 && g.mask == nil && g.vectorMask == nil && !g.effects.hasAny { c.sameAppearance() }
        }))

        // ---------- Artboard from layers
        cmds.append(QACmd(name: "Artboard from Layers", attrs: false, applies: { c in hasBounds(c) && !c.layer0.isArtboard },
                          run: { _ in AppActions.artboardFromLayers() }, verify: { c in
            guard let ab = c.active, let rect = ab.artboard?.rect else { c.check(false, "artboard created"); return }
            // (the document becomes an artboard document: Auto-size Canvas may grow the canvas on the left / top, which
            // moves everything by the document's new origin — nothing moves relative to anything else)
            let o = c.d.state.artboardOrigin
            let want = QATransforms.unionBounds(c.st0, c.ids)!.integral.offsetBy(dx: o.x, dy: o.y)
            c.check(rect == want, "artboard fits the layers", "\(LQA.fmt(rect)) vs \(LQA.fmt(want))")
            for id in c.ids {
                if let a = c.st0.layer(id), let b = c.d.state.layer(id) {
                    c.check(Compositor.shared.contentBounds(a, state: c.st0)?.offsetBy(dx: o.x, dy: o.y) == Compositor.shared.contentBounds(b, state: c.d.state), "layers stay where they were")
                }
            }
        }))

        // ---------- Merge
        cmds.append(QACmd(name: "Merge Down", key: true, replacesStack: true, applies: { c in single(c) }, run: { _ in AppActions.mergeDown() }, verify: { c in
            guard let m = c.active, m.isRaster else { c.check(false, "merged pixel layer"); return }
            let lossy = c.subj.has("blendmode") || c.subj.has("blendfx") || c.subj.has("knockout") || c.subj.has("noContent")
                || c.subj.name.hasPrefix("blendif") || c.subj.name.hasPrefix("channels") || c.subj.name == "clip.base" || c.subj.name.hasPrefix("group.normal")
            if lossy { LQA.note("Merge Down bakes blend modes / Blend If / adjustments against the merged layers only (same as Photoshop)") }
            else { c.sameAppearance(mean: 0.8, bad: 0.006) }
            if let cb = Compositor.shared.contentBounds(m, state: c.d.state) { c.check(LQA.finite(cb) && cb.width > 0, "merged layer has bounds") }
        }))
        cmds.append(QACmd(name: "Merge Visible", key: true, replacesStack: true, run: { _ in AppActions.mergeVisible() }, verify: { c in
            c.sameAppearance(mean: 0.3, bad: 0.001)
            let hidden = c.st0.allLayers.filter { !$0.isVisible && !$0.isGroup }.map(\.id)
            c.check(hidden.allSatisfy { c.d.state.layer($0) != nil }, "hidden layers are kept")
        }))
        cmds.append(QACmd(name: "Stamp Visible", run: { c in c.d.activeLayerID = nil; c.d.selectedLayerIDs = []; AppActions.stampVisible() }, verify: { c in
            c.sameAppearance(mean: 0.6, bad: 0.004)
            c.check(c.d.state.allLayers.count == c.st0.allLayers.count + 1, "stamp added on top, nothing removed")
        }))
        cmds.append(QACmd(name: "Flatten Image", key: true, replacesStack: true, run: { _ in AppActions.flattenImage() }, verify: { c in
            if c.subj.has("artboard") && (c.st0.width != LQA.W || c.st0.height != LQA.H) {
                // Auto-size Canvas grew the canvas past the Background layer: Flatten fills that transparent pasteboard white
                LQA.note("artboard documents: Flatten Image fills the transparent pasteboard (canvas grown by Auto-size Canvas) with white")
            } else {
                c.sameAppearance(mean: 0.3, bad: 0.001)
            }
            c.check(c.d.state.layers.count == 1, "single background layer")
        }))

        // ---------- Arrange
        for (n, a) in [("Bring to Front", AppActions.Arrange.front), ("Bring Forward", .forward), ("Send Backward", .backward), ("Send to Back", .back)] {
            cmds.append(QACmd(name: n, attrs: false, applies: single, run: { _ in AppActions.arrange(a) }, verify: { c in
                guard let l = c.layer else { c.check(false, "layer kept"); return }
                c.attrsKept(c.layer0, l)
                c.check(Set(c.d.state.allLayers.map(\.id)) == Set(c.st0.allLayers.map(\.id)), "same layers, new order")
            }))
        }

        // ---------- Align
        for (n, m) in [("Align Left", AlignMode.left), ("Align Horizontal Centers", .hCenter), ("Align Right", .right), ("Align Top", .top), ("Align Vertical Centers", .vCenter), ("Align Bottom", .bottom)] {
            cmds.append(QACmd(name: n, attrs: false, applies: { c in single(c) && hasBounds(c) }, run: { _ in AppActions.align(m) }, verify: { c in
                guard let l = c.layer, let b = Compositor.shared.contentBounds(l, state: c.d.state), let b0 = Compositor.shared.contentBounds(c.layer0, state: c.st0) else { return }
                let cv = c.d.state.canvasCGRect
                var off: CGFloat = 0
                switch m {
                case .left: off = b.minX - cv.minX
                case .hCenter: off = b.midX - cv.midX
                case .right: off = b.maxX - cv.maxX
                case .top: off = b.minY - cv.minY
                case .vCenter: off = b.midY - cv.midY
                case .bottom: off = b.maxY - cv.maxY
                }
                if c.layer0.isFill { return }
                c.check(abs(off) <= 1, "bounds edge sits on the canvas edge", "off by \(off)")
                c.check(abs(b.width - b0.width) < 0.01 && abs(b.height - b0.height) < 0.01, "size unchanged")
                c.attrsKept(c.layer0, l)
                // what is drawn must be aligned too, not just the box
                if let ab = LQA.alphaBounds(l, c.d.state), !c.subj.has("loose"), !l.isText, !(l.shape.map { !$0.stroke.paint.isNone } ?? false), l.smart?.filters.isEmpty ?? true {
                    var drawn: CGFloat = 0
                    switch m {
                    case .left: drawn = ab.minX - cv.minX
                    case .hCenter: drawn = ab.midX - cv.midX
                    case .right: drawn = ab.maxX - cv.maxX
                    case .top: drawn = ab.minY - cv.minY
                    case .vCenter: drawn = ab.midY - cv.midY
                    case .bottom: drawn = ab.maxY - cv.maxY
                    }
                    c.check(abs(drawn) <= 2, "drawn pixels are aligned", "off by \(drawn)")
                }
            }))
        }

        // ---------- Flip / rotate (Edit ▸ Transform)
        cmds.append(QACmd(name: "Flip Horizontal ×2", steps: 2, applies: { c in hasBounds(c) && !isLocked(c) }, run: { _ in AppActions.flipLayers(horizontal: true); AppActions.flipLayers(horizontal: true) }, verify: { c in
            c.sameAppearance("flipping twice restores the appearance", mean: 0.5, bad: 0.003)
            for id in c.ids { if let a = c.st0.layer(id), let b = c.d.state.layer(id) { c.attrsKept(a, b); c.check(LQA.kind(a) == LQA.kind(b), "layer kind kept") } }
        }))
        cmds.append(QACmd(name: "Flip Vertical ×2", attrs: false, steps: 2, applies: { c in hasBounds(c) && !isLocked(c) }, run: { _ in AppActions.flipLayers(horizontal: false); AppActions.flipLayers(horizontal: false) }, verify: { c in
            c.sameAppearance("flipping twice restores the appearance", mean: 0.5, bad: 0.003)
        }))
        cmds.append(QACmd(name: "Rotate 90° CW then CCW", steps: 2, applies: { c in hasBounds(c) && !isLocked(c) && !c.subj.has("artboard") }, run: { _ in AppActions.rotateLayers(degrees: 90); AppActions.rotateLayers(degrees: -90) }, verify: { c in
            c.sameAppearance("rotating back restores the appearance", mean: 0.8, bad: 0.006)
            for id in c.ids { if let a = c.st0.layer(id), let b = c.d.state.layer(id) { c.attrsKept(a, b); c.check(LQA.kind(a) == LQA.kind(b), "layer kind kept") } }
        }))
        cmds.append(QACmd(name: "Rotate 180° ×2", attrs: false, steps: 2, applies: { c in hasBounds(c) && !isLocked(c) && !c.subj.has("artboard") }, run: { _ in AppActions.rotateLayers(degrees: 180); AppActions.rotateLayers(degrees: 180) }, verify: { c in
            if c.subj.has("pattern") { LQA.note("pattern fills are sampled on the pixel grid of their bounds: float noise in a transform can shift the pattern by a pixel") }
            else { c.sameAppearance("rotating twice restores the appearance", mean: 0.8, bad: 0.006) }
        }))
        cmds.append(QACmd(name: "Rotate 90° CW", attrs: false, applies: { c in single(c) && hasBounds(c) && !isLocked(c) && !c.layer0.isGroup && !c.layer0.isFill }, run: { _ in AppActions.rotateLayers(degrees: 90) }, verify: { c in
            guard let l = c.layer, let b0 = Compositor.shared.contentBounds(c.layer0, state: c.st0), let b1 = Compositor.shared.contentBounds(l, state: c.d.state) else { return }
            c.check(abs(b1.width - b0.height) <= 1.5 && abs(b1.height - b0.width) <= 1.5 && abs(b1.midX - b0.midX) <= 1.5 && abs(b1.midY - b0.midY) <= 1.5,
                    "bounds are the rotated bounds", "\(LQA.fmt(b0)) → \(LQA.fmt(b1))")
            QATransforms.checkGeometry(l, c.d.state, subject: c.subj, label: c.label, check: "\(c.group): bounds match the drawn pixels")
        }))

        // ---------- Warps
        func warpVerify(_ c: QACtx) {
            guard let l = c.layer else { c.check(false, "layer kept"); return }
            c.check(LQA.kind(l) == LQA.kind(c.layer0), "layer kind kept", "\(LQA.kind(c.layer0)) → \(LQA.kind(l))")
            c.attrsKept(c.layer0, l)
            if let a = c.layer0.smart, let b = l.smart { c.check(b.warp != nil && a.filters == b.filters && a.sourceRevision == b.sourceRevision, "smart object warped non-destructively") }
            QATransforms.checkGeometry(l, c.d.state, subject: c.subj, label: c.label, check: "\(c.group): bounds match the drawn pixels")
            if let ref = c.notes["twin"] as? PixelBuffer {
                let got = LQA.render(c.d.state, blur: 2)
                let df = LQA.diff(got, ref, threshold: 40)
                let ok = df.within(mean: 2.0, bad: 0.012)
                if !ok { LQA.dumpPair(ref, got, "\(c.group)_\(c.label)") }
                c.check(ok, "result looks like the warped pixels", df.description)
            }
        }
        /// Reference: the layer with its linked mask baked in (masks warp with the layer), rasterized, then warped.
        func twinWarp(_ c: QACtx, _ warpIt: (Document, UUID) -> Bool) {
            guard !c.subj.has("stroke"), !c.subj.has("gradient"), !c.subj.has("pattern"), !c.subj.has("filters"), !c.subj.has("fx") else { return }
            if c.subj.name == "shape.path.boolean" { return }     // its warp box includes the subtracted component
            if let cb = Compositor.shared.contentBounds(c.layer0, state: c.st0), !LQA.contentArea(c.st0).cgRect.contains(cb) { return }   // twin would miss off-canvas content
            var st = c.st0
            let masked = c.layer0.mask != nil || c.layer0.vectorMask != nil
            if masked, let cb = Compositor.shared.contentBounds(c.layer0, state: c.st0), !c.st0.canvasCGRect.contains(cb) { return }   // the baked twin is canvas-sized
            let t = QATransforms.bakedTwin(c.layer0, c.st0, keepBounds: true) ?? QATransforms.twin(c.layer0, c.st0)
            st.updateLayer(t.id) { $0 = t }
            c.notes["twin"] = LQA.withDoc(st, select: [t.id]) { td -> PixelBuffer? in warpIt(td, t.id) ? LQA.render(td.state, blur: 2) : nil }
        }
        let canWarp: (QACtx) -> Bool = { c in single(c) && WarpApply.canWarp(c.layer0) && !c.layer0.locks.positionLocked && hasBounds(c) }
        for style in [WarpStyle.arc, .flag, .fisheye, .twist, .inflate, .arch] {
            cmds.append(QACmd(name: "Warp preset \(style.displayName)", key: style == .arc, attrs: style == .arc || style == .twist, applies: canWarp, run: { c in
                twinWarp(c) { d, id in QATransforms.warp(doc: d, id: id, style: style, bend: 0.45) }
                QATransforms.warp(doc: c.d, id: c.id, style: style, bend: 0.45)
            }, verify: warpVerify))
        }
        cmds.append(QACmd(name: "Warp (split grid, cylinder)", attrs: false, applies: canWarp, run: { c in
            let go: (Document, UUID) -> Bool = { d, id in
                guard let s = SplitWarpSession(doc: d, layerID: id) else { return false }
                s.style = .cylinder; s.bend = 0.6; s.commit(); return true
            }
            twinWarp(c, go)
            _ = go(c.d, c.id)
        }, verify: warpVerify))
        cmds.append(QACmd(name: "Puppet Warp", applies: canWarp, run: { c in
            let go: (Document, UUID) -> Bool = { d, id in
                guard let s = PuppetWarpSession(doc: d, layerID: id) else { return false }
                let b = s.bounds
                let a = CGPoint(x: b.minX + b.width * 0.2, y: b.minY + b.height * 0.3), e = CGPoint(x: b.maxX - b.width * 0.2, y: b.maxY - b.height * 0.3)
                s.pins = [(a, a), (e, e + CGPoint(x: 18, y: -14)), (CGPoint(x: b.midX, y: b.maxY - 4), CGPoint(x: b.midX, y: b.maxY - 4))]
                s.updatePreview(); s.commit(); return true
            }
            twinWarp(c, go)
            _ = go(c.d, c.id)
        }, verify: warpVerify))
        cmds.append(QACmd(name: "Perspective Warp", applies: canWarp, run: { c in
            let go: (Document, UUID) -> Bool = { d, id in
                guard let s = PerspectiveWarpSession(doc: d, layerID: id) else { return false }
                s.mode = .warp
                s.warped[1] = s.warped[1] + CGPoint(x: -14, y: 16)
                s.warped[2] = s.warped[2] + CGPoint(x: 10, y: -8)
                s.updatePreview(); s.commit(); return true
            }
            twinWarp(c, go)
            _ = go(c.d, c.id)
        }, verify: warpVerify))
        cmds.append(QACmd(name: "Content-Aware Scale", attrs: false, applies: { c in single(c) && c.layer0.isRaster && !c.layer0.locks.pixelsLocked && hasBounds(c) }, run: { c in
            guard let s = ContentAwareScaleSession(doc: c.d, layerID: c.id) else { return }
            s.target = CGRect(x: s.source.minX, y: s.source.minY, width: (s.source.width * 0.75).rounded(), height: s.source.height)
            c.notes["target"] = s.target
            s.updatePreview(); s.commit()
        }, verify: { c in
            guard let l = c.layer, let t = c.notes["target"] as? CGRect, let b = Compositor.shared.contentBounds(l, state: c.d.state) else { return }
            c.check(LQA.close(b, t, 2), "content fills the scaled box", "\(LQA.fmt(b)) vs \(LQA.fmt(t))")
            c.attrsKept(c.layer0, l)
        }))

        cmds.append(QACmd(name: "Cancel Warp / Puppet / Perspective Warp / Content-Aware Scale / Free Transform", alwaysVerify: true, applies: { c in single(c) && hasBounds(c) && !c.layer0.locks.positionLocked }, run: { c in
            var left: [String] = []
            func done(_ n: String) { if !c.d.contentOverrides.isEmpty { left.append(n); c.d.contentOverrides.removeAll() } }
            if let s = WarpSession(doc: c.d, layerID: c.id) { s.style = .flag; s.cancel(); done("Warp") }
            if let s = SplitWarpSession(doc: c.d, layerID: c.id) { s.style = .cylinder; s.updatePreview(); s.cancel(); done("Warp (split)") }
            if let s = PuppetWarpSession(doc: c.d, layerID: c.id) { s.pins = [(s.bounds.origin, s.bounds.origin + CGPoint(x: 9, y: 9))]; s.updatePreview(); s.cancel(); done("Puppet Warp") }
            if let s = PerspectiveWarpSession(doc: c.d, layerID: c.id) { s.mode = .warp; s.warped[0] = s.warped[0] + CGPoint(x: 9, y: 9); s.updatePreview(); s.cancel(); done("Perspective Warp") }
            if let s = ContentAwareScaleSession(doc: c.d, layerID: c.id) { s.target = s.source.insetBy(dx: 10, dy: 0); s.updatePreview(); s.cancel(); done("Content-Aware Scale") }
            if let s = TransformSession(doc: c.d, layerIDs: [c.id]) { s.quad = s.quad.mapped { $0 + CGPoint(x: 15, y: 5) }; s.updatePreview(); s.cancel(); done("Free Transform") }
            c.notes["left"] = left
        }, verify: { c in
            let left = c.notes["left"] as? [String] ?? []
            c.check(left.isEmpty, "cancelling leaves no preview on the layer", left.joined(separator: ", "))
            c.check(LQA.Snapshot(c.d.state).matches(LQA.Snapshot(c.st0)), "cancelling leaves the document untouched")
        }))

        // ---------- Smart object contents
        let isSmart: (QACtx) -> Bool = { c in single(c) && c.layer0.isSmartObject && !c.subj.has("video") }
        cmds.append(QACmd(name: "Edit Contents, save unchanged", key: true, applies: isSmart, run: { c in
            AppActions.editSmartContents(c.id)
            guard let child = AppModel.shared.activeDocument, child.smartParent === c.d else { return }
            AppActions.updateSmartObject(parent: c.d, layerID: c.id, from: child)
            AppModel.shared.close(child)
            AppModel.shared.activeDocumentID = c.d.id
        }, verify: { c in
            guard let a = c.layer0.smart, let b = c.layer?.smart else { c.check(false, "still a smart object"); return }
            c.check(a.quad == b.quad && a.filters == b.filters && a.warp == b.warp && a.stackMode == b.stackMode, "placement, filters and warp kept")
            c.sameAppearance(mean: 0.3, bad: 0.002)
        }))
        cmds.append(QACmd(name: "Edit Contents, resize canvas, save", applies: isSmart, run: { c in
            AppActions.editSmartContents(c.id)
            guard let child = AppModel.shared.activeDocument, child.smartParent === c.d else { return }
            AppActions.canvasSize(width: child.state.width + 40, height: child.state.height + 20, anchorX: 0, anchorY: 0, extension: nil)
            AppActions.updateSmartObject(parent: c.d, layerID: c.id, from: child)
            AppModel.shared.close(child)
            AppModel.shared.activeDocumentID = c.d.id
        }, verify: { c in
            guard let a = c.layer0.smart, let b = c.layer?.smart else { c.check(false, "still a smart object"); return }
            let sz = a.source.size
            let kx = (sz.width + 40) / sz.width, ky = (sz.height + 20) / sz.height
            let U = a.quad.tr - a.quad.tl, V = a.quad.bl - a.quad.tl
            let want = Quad(tl: a.quad.tl, tr: a.quad.tl + U * kx, br: a.quad.tl + U * kx + V * ky, bl: a.quad.tl + V * ky)
            if a.quad.isAffine { c.check(QATransforms.quadClose(want, b.quad, 0.01), "content keeps its scale and position (the box grows with the canvas)") }
            else if let place = Homography(from: Quad(rect: CGRect(origin: .zero, size: sz)), to: a.quad) {
                let wantP = Quad(rect: CGRect(x: 0, y: 0, width: sz.width + 40, height: sz.height + 20)).mapped(place.apply)
                c.check(QATransforms.quadClose(wantP, b.quad, 0.05), "perspective placement kept (the box grows with the canvas)")
                c.sameAppearance("existing pixels stay where they were", mean: 0.8, bad: 0.006)
            }
            // the old pixels must not move: compare inside the old quad
            if a.warp == nil, a.filters.isEmpty, a.quad.isAffine, a.stackMode == nil, !c.subj.has("fx") { c.sameAppearance("existing pixels stay where they were", mean: 0.6, bad: 0.004) }
            c.check(a.filters == b.filters, "filters kept")
        }))
        cmds.append(QACmd(name: "Convert to Linked, reload from the file", attrs: false, steps: 1, applies: { c in isSmart(c) && c.layer0.smart?.linkedURL == nil && c.layer0.smart?.stackMode == nil }, run: { c in
            let url = LQA.out.appendingPathComponent("qa_convert_linked.imagecrat")
            try? AppActions.convertToLinked(c.id, in: c.d, to: url)
            c.notes["linked"] = c.d.state.layer(c.id)?.smart?.linkedURL == url && FileManager.default.fileExists(atPath: url.path)
            // what reopening the document does: load the source from the file again
            let tmp = Document(state: c.d.state, name: "reload")
            AppActions.updateModifiedLinkedContent(tmp, all: true, commit: false)
            c.notes["reloaded"] = tmp.state
        }, verify: { c in
            c.check(c.notes["linked"] as? Bool == true, "layer is linked to the written file")
            guard let a = c.layer0.smart, let b = c.layer?.smart else { return }
            c.check(a.quad == b.quad && a.filters == b.filters && a.warp == b.warp, "placement, filters and warp kept")
            c.sameAppearance(mean: 0.05, bad: 0)
            if let re = c.notes["reloaded"] as? DocumentState { c.sameAppearance("reloading the linked file keeps the look", mean: 0.3, bad: 0.002, of: re) }
        }))
        cmds.append(QACmd(name: "Embed Linked", attrs: false, applies: { c in isSmart(c) && c.layer0.smart?.linkedURL != nil }, run: { _ in AppActions.embedLinked() }, verify: { c in
            c.check(c.layer?.smart?.linkedURL == nil, "link removed")
            c.sameAppearance(mean: 0.05, bad: 0)
        }))
        cmds.append(QACmd(name: "Update Linked Content (file unchanged)", attrs: false, applies: { c in isSmart(c) && c.layer0.smart?.linkedURL != nil },
                          run: { c in AppActions.updateModifiedLinkedContent(c.d, all: true) }, verify: { c in
            guard let a = c.layer0.smart, let b = c.layer?.smart else { return }
            c.check(a.quad == b.quad, "placement kept")
            c.sameAppearance(mean: 0.3, bad: 0.002)
        }))

        // ---------- Masks
        let noMask: (QACtx) -> Bool = { c in single(c) && c.layer0.mask == nil }
        let hasMask: (QACtx) -> Bool = { c in single(c) && c.layer0.mask != nil }
        cmds.append(QACmd(name: "Add Mask (Reveal All)", applies: noMask, run: { _ in AppActions.addMask(.revealAll) }, verify: { c in
            c.check(c.layer?.mask != nil, "mask added")
            c.sameAppearance(mean: 0.05, bad: 0)
        }))
        cmds.append(QACmd(name: "Add Mask (Hide All)", attrs: false, applies: noMask, run: { _ in AppActions.addMask(.hideAll) }, verify: { c in
            guard let l = c.layer, !l.isAdjustment else { return }
            let b = LQA.renderLayer(l, c.d.state)
            c.check(LQA.opaqueBounds(b, threshold: 2) == nil || l.effects.hasAny, "layer is fully hidden")
        }))
        for hide in [false, true] {
            cmds.append(QACmd(name: hide ? "Add Mask (Hide Selection)" : "Add Mask (Reveal Selection)", prepare: { st, _ in rectSelection(&st) }, applies: noMask,
                              run: { _ in AppActions.addMask(hide ? .hideSelection : .revealSelection) }, verify: { c in
                guard let l = c.layer, let m = l.mask, let sel = c.st0.selection else { c.check(false, "mask added"); return }
                c.check(c.d.state.selection == nil, "selection consumed")
                let want = hide ? SelectionOps.invert(sel) : sel
                let sp = LQA.space(c.d.state)
                let outside = CIImage.color(RGBA(gray: Double(m.outsideValue) / 255), sp.ciCanvas)
                let got = RenderEngine.renderBuffer(sp.place(m.buffer, at: m.origin).composited(over: outside), docRect: c.d.state.canvasRect, space: sp, format: .gray)
                let df = LQA.diff(got, want)
                c.check(df.maxv <= 2, "mask matches the selection, in place", df.description)
            }))
        }
        cmds.append(QACmd(name: "Add Mask (From Transparency)", attrs: false, applies: { c in noMask(c) && c.layer0.isRaster }, run: { _ in AppActions.addMask(.fromTransparency) }, verify: { c in
            c.sameAppearance(mean: 0.3, bad: 0.002)
        }))
        cmds.append(QACmd(name: "Delete Mask", applies: hasMask, run: { _ in AppActions.deleteMask() }, verify: { c in
            guard let l = c.layer else { return }
            c.check(l.mask == nil, "mask removed")
            c.attrsKept(c.layer0, l, ignoring: ["mask"])
            var ref = c.st0
            ref.updateLayer(c.id) { $0.mask = nil }
            c.sameAppearance("layer shows unmasked", mean: 0.05, bad: 0, to: LQA.render(ref))
        }))
        cmds.append(QACmd(name: "Apply Mask", applies: { c in hasMask(c) && c.layer0.isRaster }, run: { _ in AppActions.applyMask() }, verify: { c in
            guard let l = c.layer else { return }
            c.check(l.mask == nil, "mask removed")
            c.attrsKept(c.layer0, l, ignoring: ["mask"])
            c.sameAppearance(mean: 0.5, bad: 0.003)
        }))
        cmds.append(QACmd(name: "Invert Mask ×2", steps: 2, applies: hasMask, run: { _ in AppActions.invertMask(); AppActions.invertMask() }, verify: { c in
            c.sameAppearance(mean: 0.05, bad: 0)
        }))
        cmds.append(QACmd(name: "Invert Mask", attrs: false, applies: hasMask, run: { _ in AppActions.invertMask() }, verify: { c in
            guard let a = c.layer0.mask, let b = c.layer?.mask else { return }
            c.check(a.origin == b.origin && a.isLinked == b.isLinked && a.feather == b.feather && a.density == b.density && b.outsideValue == 255 - a.outsideValue, "mask placement and settings kept")
        }))
        cmds.append(QACmd(name: "Disable / Enable Mask", steps: 2, applies: hasMask, run: { _ in AppActions.toggleMaskEnabled(); AppActions.toggleMaskEnabled() }, verify: { c in
            c.sameAppearance(mean: 0.05, bad: 0)
        }))
        cmds.append(QACmd(name: "Vector Mask from Path", prepare: { st, _ in
            st.paths = [NamedPath(name: "Work Path", path: VectorPath.ellipse(CGRect(x: 100, y: 80, width: 120, height: 80)))]
        }, applies: { c in single(c) && c.layer0.vectorMask == nil }, run: { c in c.d.activePathID = c.d.state.paths.first?.id; AppActions.addVectorMask() }, verify: { c in
            guard let l = c.layer else { return }
            c.check(l.vectorMask == c.st0.paths.first?.path, "vector mask is the path, in place")
            c.attrsKept(c.layer0, l, ignoring: ["vmask"])
        }))

        // ---------- Clipping
        cmds.append(QACmd(name: "Clipping Mask on / off", steps: 2, run: { _ in AppActions.toggleClippingMask(); AppActions.toggleClippingMask() }, verify: { c in
            c.sameAppearance(mean: 0.05, bad: 0)
            for id in c.ids { if let a = c.st0.layer(id), let b = c.d.state.layer(id) { c.attrsKept(a, b) } }
        }))
        cmds.append(QACmd(name: "Create Clipping Mask", attrs: false, applies: { c in single(c) && !c.layer0.isClipped }, run: { _ in AppActions.toggleClippingMask() }, verify: { c in
            guard let l = c.layer else { return }
            c.check(l.isClipped, "layer clipped")
            c.attrsKept(c.layer0, l, ignoring: ["clipped"])
            if let cb0 = Compositor.shared.contentBounds(c.layer0, state: c.st0), let cb1 = Compositor.shared.contentBounds(l, state: c.d.state) { c.check(cb0 == cb1, "bounds unchanged") }
        }))

        // ---------- Layer style clipboard
        cmds.append(QACmd(name: "Copy / Paste Layer Style", applies: single, run: { c in
            AppActions.copyLayerStyle()
            if let under = c.d.state.layers.first(where: { $0.name == "Under" }) { c.d.selectLayer(under.id) }
            AppActions.pasteLayerStyle()
        }, verify: { c in
            guard let under = c.d.state.layers.first(where: { $0.name == "Under" }) else { return }
            c.check(under.effects == c.layer0.effects, "style pasted")
            if let l = c.layer { c.attrsKept(c.layer0, l) }
        }))
        cmds.append(QACmd(name: "Clear Layer Style", applies: { c in single(c) && c.layer0.effects.hasAny }, run: { _ in AppActions.clearLayerStyle() }, verify: { c in
            guard let l = c.layer else { return }
            c.check(!l.effects.hasAny, "style cleared")
            c.attrsKept(c.layer0, l, ignoring: ["effects"])
            c.check(Compositor.shared.contentBounds(l, state: c.d.state) == Compositor.shared.contentBounds(c.layer0, state: c.st0), "bounds unchanged")
        }))

        // ---------- Clipboard
        cmds.append(QACmd(name: "Copy, Paste in Place", applies: { c in single(c) && hasBounds(c) }, run: { _ in AppActions.copy(); AppActions.paste(inPlace: true) }, verify: { c in
            guard let nl = c.active, nl.isRaster, nl.id != c.id else {
                let onCanvas = Compositor.shared.contentBounds(c.layer0, state: c.st0).map { $0.intersects(c.st0.canvasCGRect) } ?? false
                c.check(!onCanvas, "pasted layer created")
                return
            }
            guard let want = content(c.layer0, c.st0), let got = content(nl, c.d.state) else { return }
            let df = LQA.diff(want, got)
            c.check(df.within(mean: 0.4, bad: 0.003), "pasted pixels sit exactly on the original", df.description)
        }))
        cmds.append(QACmd(name: "Copy, Paste", attrs: false, applies: { c in single(c) && hasBounds(c) && !c.layer0.isFill }, run: { _ in AppActions.copy(); AppActions.paste() }, verify: { c in
            guard let nl = c.active, let r = nl.raster, nl.id != c.id else { return }
            guard let cb = Compositor.shared.contentBounds(c.layer0, state: c.st0) else { return }
            let src = IRect(enclosing: cb).intersection(c.st0.canvasRect)
            c.check(r.buffer.width == src.width && r.buffer.height == src.height, "pasted layer has the copied size", "\(r.buffer.width)×\(r.buffer.height) vs \(src.width)×\(src.height)")
            c.check(abs(r.frame.cgRect.midX - CGFloat(c.st0.width) / 2) <= 1 && abs(r.frame.cgRect.midY - CGFloat(c.st0.height) / 2) <= 1, "pasted layer is centred")
        }))
        cmds.append(QACmd(name: "Copy Merged, Paste in Place", attrs: false, prepare: { st, _ in rectSelection(&st) }, run: { c in
            AppActions.copy(merged: true)
            c.d.activeLayerID = nil; c.d.selectedLayerIDs = []     // paste on top of the stack (an expanded group would take the layer in)
            AppActions.paste(inPlace: true)
        }, verify: { c in
            guard let nl = c.active, let r = nl.raster else { c.check(false, "pasted layer created"); return }
            c.check(r.frame.cgRect == selRect, "pasted layer covers the selection", LQA.fmt(r.frame.cgRect))
            c.sameAppearance("pasting the merged copy in place changes nothing", mean: 0.6, bad: 0.004)
        }))
        cmds.append(QACmd(name: "Cut (selection)", attrs: false, prepare: { st, _ in rectSelection(&st) }, applies: { c in single(c) && c.layer0.isRaster && !c.layer0.locks.pixelsLocked }, run: { _ in AppActions.cut() }, verify: { c in
            guard let l = c.layer, let rest = content(l, c.d.state, mask: c.st0.selection) else { return }
            c.check(LQA.opaqueBounds(rest, threshold: 2) == nil, "selected pixels removed")
            c.attrsKept(c.layer0, l)
            if let clip = AppActions.clipboard { c.check(clip.origin == IPoint(x: Int(selRect.minX), y: Int(selRect.minY)), "clipboard remembers the position") }
        }))

        // ---------- Type conversions
        let isText: (QACtx) -> Bool = { c in single(c) && c.layer0.isText }
        cmds.append(QACmd(name: "Convert Text to Shape", key: true, applies: isText, run: { _ in AppActions.convertTextToShape() }, verify: { c in
            guard let l = c.layer, l.isShape else { c.check(false, "result is a shape layer"); return }
            c.attrsKept(c.layer0, l)
            let t = c.layer0.text!
            let decorated = t.underline || t.strikethrough || t.runs.contains { $0.style.underline == true || $0.style.strikethrough == true || $0.style.color != nil }
            if decorated { LQA.note("Convert to Shape drops underline / strikethrough and per-run colours (one fill per shape layer)") }
            else {
                // glyphs drawn as text and as filled outlines differ by a fraction of a pixel along every edge
                let df = LQA.diff(LQA.render(c.st0, blur: 1.2), LQA.render(c.d.state, blur: 1.2))
                c.check(df.within(mean: 1.8, bad: 0.006), "appearance preserved", df.description)
            }
            if let ab0 = LQA.alphaBounds(c.layer0, c.st0), let ab1 = LQA.alphaBounds(l, c.d.state), !decorated {
                c.check(LQA.close(ab0, ab1, 3), "outlines sit on the glyphs", "\(LQA.fmt(ab0)) vs \(LQA.fmt(ab1))")
            }
        }))
        cmds.append(QACmd(name: "Create Work Path from Text", attrs: false, applies: isText, run: { _ in AppActions.createWorkPathFromText() }, verify: { c in
            guard let p = c.d.state.paths.last, let ab = LQA.alphaBounds(c.layer0, c.st0) else { c.check(false, "work path created"); return }
            let t = c.layer0.text!
            if t.underline || t.strikethrough || !t.runs.isEmpty { return }
            let vis = LQA.contentArea(c.st0).cgRect
            c.check(LQA.close(p.path.bounds.intersection(vis), ab, 3), "path sits on the glyphs", "\(LQA.fmt(p.path.bounds)) vs \(LQA.fmt(ab))")
            if let l = c.layer { c.check(l.isText, "type layer kept") }
        }))
        cmds.append(QACmd(name: "Convert to Paragraph Text", applies: { c in isText(c) && c.layer0.text!.isPointText && c.layer0.text!.orientation == .horizontal },
                          run: { _ in TypeActions2.convert("Convert to Paragraph Text") { $0.convertToParagraphText() } }, verify: { c in
            guard let l = c.layer, let t = l.text else { return }
            c.check(t.boxSize != nil, "text has a box")
            c.check(t.transform == c.layer0.text!.transform, "transform kept")
            if t.warp != nil { LQA.note("Warp Text bends relative to the text box: giving point text a (slightly larger) paragraph box changes the bend a little") }
            else { c.sameAppearance(mean: 0.5, bad: 0.004) }
        }))
        cmds.append(QACmd(name: "Convert to Point Text", applies: { c in isText(c) && c.layer0.text!.boxSize != nil && c.layer0.text!.pathText == nil },
                          run: { _ in TypeActions2.convert("Convert to Point Text") { $0.convertToPointText() } }, verify: { c in
            guard let l = c.layer, let t = l.text else { return }
            c.check(t.boxSize == nil && t.area == nil, "box removed")
            c.check(t.transform == c.layer0.text!.transform, "transform kept")
            if c.layer0.text!.area != nil || c.layer0.text!.alignment.isJustified || c.layer0.text!.list != nil { return }
            c.sameAppearance(mean: 0.9, bad: 0.008)
        }))

        // ---------- Links
        cmds.append(QACmd(name: "Link, transform, unlink", attrs: false, steps: 3, applies: { c in single(c) && hasBounds(c) && !isLocked(c) && c.layer0.linkID == nil }, run: { c in
            guard let under = c.d.state.layers.first(where: { $0.name == "Under" }) else { return }
            c.d.selectedLayerIDs = [under.id, c.id]; c.d.activeLayerID = c.id
            AppActions.toggleLinkLayers()
            c.notes["linked"] = c.d.state.layer(c.id)?.linkID != nil && c.d.state.layer(c.id)?.linkID == c.d.state.layer(under.id)?.linkID
            c.d.selectLayer(c.id)
            let all = c.d.withLinked([c.id])
            c.notes["all"] = all.count
            if let b = QATransforms.unionBounds(c.d.state, all) {
                let h = Homography(affine: CGAffineTransform(translationX: 21, y: 13))
                c.notes["box"] = b
                QATransforms.apply(h, doc: c.d, ids: [c.id])
            }
            c.d.selectedLayerIDs = [under.id, c.id]
            AppActions.toggleLinkLayers()
            c.d.selectLayer(c.id)
        }, verify: { c in
            c.check(c.notes["linked"] as? Bool == true && c.notes["all"] as? Int == 2, "layers linked")
            guard let u0 = c.st0.layers.first(where: { $0.name == "Under" }), let u1 = c.d.state.layer(u0.id), let l = c.layer else { return }
            c.check(u1.raster?.origin == IPoint(x: (u0.raster?.origin.x ?? 0) + 21, y: (u0.raster?.origin.y ?? 0) + 13), "linked layer moved along")
            c.check(u1.linkID == nil && l.linkID == nil, "layers unlinked")
            if let b0 = Compositor.shared.contentBounds(c.layer0, state: c.st0), let b1 = Compositor.shared.contentBounds(l, state: c.d.state), !l.isFill {
                c.check(LQA.close(b0.offsetBy(dx: 21, dy: 13), b1, 0.6), "layer moved", "\(LQA.fmt(b0)) → \(LQA.fmt(b1))")
            }
        }))

        // ---------- Layer comps
        cmds.append(QACmd(name: "Layer Comp capture, change, apply", attrs: false, steps: 3, applies: { c in hasBounds(c) }, run: { c in
            AppActions.newLayerComp()
            for id in c.ids { c.d.updateLayer(id) { $0.translate(dx: 26, dy: -17); $0.opacity = 0.4; $0.isVisible.toggle() } }
            c.d.commit("Edit")
            if let comp = c.d.state.layerComps.last { AppActions.applyLayerComp(comp.id) }
        }, verify: { c in
            c.sameAppearance("applying the comp restores the look", mean: 0.6, bad: 0.004)
            for id in c.ids {
                guard let a = c.st0.layer(id), let b = c.d.state.layer(id) else { continue }
                c.attrsKept(a, b)
                if let b0 = Compositor.shared.contentBounds(a, state: c.st0), let b1 = Compositor.shared.contentBounds(b, state: c.d.state) {
                    c.check(LQA.close(b0, b1, 0.6), "applying the comp restores the position", "\(LQA.fmt(b0)) → \(LQA.fmt(b1))")
                }
            }
        }))

        // ---------- History
        cmds.append(QACmd(name: "History jump / snapshot revert", attrs: false, steps: 3, run: { c in
            let snap = SnapshotStore.shared.newSnapshot(c.d, name: "qa")
            AppActions.duplicateLayers()
            AppActions.flipLayers(horizontal: true)
            c.notes["mid"] = LQA.Snapshot(c.d.state)
            c.d.jumpToHistory(0)
            c.notes["jump0"] = LQA.Snapshot(c.d.state)
            c.d.jumpToHistory(c.d.history.count - 1)
            c.notes["jumpLast"] = LQA.Snapshot(c.d.state)
            SnapshotStore.shared.revert(c.d, to: snap)
            SnapshotStore.shared.delete(c.d, snap.id)
        }, verify: { c in
            let orig = LQA.Snapshot(c.st0)
            c.check((c.notes["jump0"] as? LQA.Snapshot)?.matches(orig) == true, "jumping to the first history state restores it")
            if let a = c.notes["mid"] as? LQA.Snapshot, let b = c.notes["jumpLast"] as? LQA.Snapshot { c.check(a.matches(b), "jumping to the last history state restores it") }
            c.check(LQA.Snapshot(c.d.state).matches(orig), "reverting to the snapshot restores the document")
        }))

        return cmds
    }

    // MARK: File round trips (per subject variant)

    static func psdLossy(_ subj: QASubject, _ st: DocumentState) -> String? {
        // adjustment, fill, shape, type and smart object layers, Blend If, knockout, channel restrictions and artboards are written live (PSDExport)
        if subj.name.hasPrefix("fx.multi") { return "PSD export writes one instance of each layer effect (extra drop shadows / strokes are lost)" }
        return nil
    }

    static var psdCounter = 0

    static func fileRoundTrips(_ subj: QASubject, _ xf: String?, _ st: DocumentState, _ ids: [UUID]) {
        let label = subj.name + (xf.map { " [\($0)]" } ?? "")
        let G = "m2.files"
        let ref = LQA.render(st)
        if LQA.cmdFilter.map({ "lumen".contains($0.lowercased()) || $0.lowercased().contains("lumen") }) ?? true {
            let url = LQA.out.appendingPathComponent("qa_roundtrip.imagecrat")
            do {
                try DocumentIO.saveNative(Document(state: st, name: "rt"), to: url)
                let back = try DocumentIO.load(url: url)
                LQA.check(LQA.Snapshot(back.state).matches(LQA.Snapshot(st)), "\(G): .imagecrat save / load is lossless (re-encodes identically)", label)
                LQA.check(Set(back.state.generative.keys) == Set(st.generative.keys) && back.state.toolData.frames == st.toolData.frames, "\(G): .imagecrat keeps generative and frame metadata", label)
                let df = LQA.diff(ref, LQA.render(back.state))
                LQA.check(df.maxv <= 1, "\(G): .imagecrat save / load renders identically", label, df.description)
            } catch { LQA.check(false, "\(G): .imagecrat save / load", label, "\(error)") }
        }
        psdCounter += xf == nil ? 1 : 0
        let psdWanted = LQA.full || (xf == nil && (subj.core || ["mask", "vmask", "clip", "fx", "fill", "blend", "knock", "hidden", "adjustment.invert"].contains { subj.name.hasPrefix($0) }))
        if psdWanted, LQA.cmdFilter.map({ $0.lowercased().contains("psd") || $0.lowercased().contains("psb") }) ?? true {
            for large in (xf == nil && (LQA.full || psdCounter % 8 == 1) ? [false, true] : [false]) {
                let url = LQA.out.appendingPathComponent(large ? "qa_roundtrip.psb" : "qa_roundtrip.psd")
                let name = large ? "PSB" : "PSD"
                do {
                    try PSDWriter.write(st, to: url, large: large)
                    let back = try PSDReader.read(url: url)
                    LQA.check(back.width == st.width && back.height == st.height, "\(G): \(name) keeps the canvas size", label)
                    if let why = psdLossy(subj, st) { LQA.note("\(name): " + why) }
                    else {
                        let got = LQA.render(back)
                        let df = LQA.diff(ref, got)
                        let ok = df.within(mean: 1.2, bad: 0.008)
                        if !ok { LQA.dumpPair(ref, got, "\(name)_\(label)") }
                        LQA.check(ok, "\(G): \(name) export → import looks the same", label, df.description)
                    }
                    // structure: every layer comes back with its name, visibility, opacity and blend mode
                    let want = st.allLayers
                    let have = back.allLayers
                    var missing: [String] = []
                    for l in want {
                        guard let m = have.first(where: { $0.name == l.name && $0.isGroup == l.isGroup }) else {
                            // fully off-canvas or empty layers have no pixels to write
                            if l.isGroup || LQA.alphaBounds(l, st).map({ $0.intersects(st.canvasCGRect) }) ?? false { missing.append(l.name) }
                            continue
                        }
                        let mode = l.blendMode == .passThrough && !l.isGroup ? BlendMode.normal : l.blendMode
                        // pixel and vector masks both travel live
                        let wantMask = l.mask != nil, wantVector = !(l.vectorMask?.isEmpty ?? true)
                        if m.isVisible != l.isVisible || abs(m.opacity - l.opacity) > 0.01 || (m.blendMode != mode && !(l.isGroup && m.blendMode == .passThrough))
                            || m.isClipped != l.isClipped || (m.mask == nil) == wantMask || (m.vectorMask?.isEmpty ?? true) == wantVector
                            || abs(m.fillOpacity - l.fillOpacity) > 0.01 {
                            missing.append("\(l.name) (attributes)")
                        }
                    }
                    LQA.check(missing.isEmpty, "\(G): \(name) keeps layers, names, visibility, opacity, blend mode, clipping and masks", label, missing.joined(separator: ", "))
                } catch { LQA.check(false, "\(G): \(name) export → import", label, "\(error)") }
            }
        }
        if xf == nil, LQA.full || subj.core, LQA.cmdFilter.map({ $0.lowercased().contains("png") }) ?? true {
            let url = LQA.out.appendingPathComponent("qa_roundtrip.png")
            do {
                try DocumentIO.export(st, to: url, format: .png, quality: 1, scale: 1)
                let back = try DocumentIO.load(url: url)
                let df = LQA.diff(ref, LQA.render(back.state))
                LQA.check(df.within(mean: 0.6, bad: 0.0005), "\(G): PNG export matches the composite", label, df.description)
            } catch { LQA.check(false, "\(G): PNG export", label, "\(error)") }
        }
    }
}
