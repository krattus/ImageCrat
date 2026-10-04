import AppKit
import CoreImage
import ImageCratCore

enum AlignMode { case left, hCenter, right, top, vCenter, bottom }
enum MaskInit { case revealAll, hideAll, revealSelection, hideSelection, fromTransparency }

extension AppActions {
    // MARK: Create

    static func newLayer() {
        ActionRecorder.record(.newLayer)
        guard let d = doc else { return }
        d.addLayer(Layer.raster(name: d.nextLayerName(), width: d.state.width, height: d.state.height), commitName: "New Layer")
    }

    static func newGroup() {
        guard let d = doc else { return }
        let g = Layer(name: d.nextLayerName("Group"), content: .group(GroupContent()))
        d.addLayer(g, commitName: "New Group")
    }

    static func newFillLayer(_ paint: PaintStyle, name: String) {
        guard let d = doc else { return }
        var l = Layer(name: d.nextLayerName(name), content: .fill(FillContent(paint: paint)))
        if let sel = d.state.selection {
            l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0)
            d.state.selection = nil
        }
        d.addLayer(l, commitName: "New \(name) Layer")
    }

    static func newAdjustmentLayer(_ kind: AdjustmentKind) {
        ActionRecorder.record(.adjustmentLayer(kind))
        guard let d = doc else { return }
        var l = Layer(name: d.nextLayerName(kind.displayName), content: .adjustment(AdjustmentSettings(kind: kind)))
        if let sel = d.state.selection {
            l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0)
            d.state.selection = nil
        } else {
            l.mask = LayerMask.reveal(width: d.state.width, height: d.state.height)
        }
        d.addLayer(l, commitName: "New \(kind.displayName) Layer")
        app.showPanels = true
    }

    /// Cmd+J: copy selected pixels (or the whole layer) to a new layer.
    static func layerViaCopy(cut: Bool = false) {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id) else { return }
        guard let sel = d.state.selection else {
            duplicateLayers()
            return
        }
        let sp = space(d)
        guard var content = Compositor.shared.contentImage(l, space: sp) else { return }
        content = content.masked(byGray: sel.ciImage.composited(over: CIImage.color(.black, content.extent.union(sp.ciCanvas))))
        guard let b = sel.opaqueBounds() else { return }
        let buf = RenderEngine.renderBuffer(content, docRect: b, space: sp)
        if cut && l.isRaster {
            clearSelectionPixels(name: "Cut", commit: false)   // one history step: "Layer via Cut"
        }
        let nl = Layer.raster(name: cut ? "Layer via Cut" : "Layer via Copy", buffer: buf, origin: b.origin)
        d.state.insertLayer(nl, above: id)
        d.activeLayerID = nl.id
        d.selectedLayerIDs = [nl.id]
        d.commit(cut ? "Layer via Cut" : "Layer via Copy")
    }

    static func duplicateLayers(commit: Bool = true) {
        if commit { ActionRecorder.record(.duplicateLayer) }
        guard let d = doc else { return }
        var newIDs: [UUID] = []
        for id in d.orderedSelection.reversed() {
            guard let l = d.state.layer(id) else { continue }
            let copy = l.duplicated(newName: l.name + " copy")
            d.state.insertLayer(copy, above: id)
            newIDs.append(copy.id)
        }
        if let f = newIDs.first { d.activeLayerID = f }
        d.selectedLayerIDs = Set(newIDs)
        if commit { d.commit("Duplicate Layer") }
    }

    static func deleteLayers() {
        guard let d = doc else { return }
        let ids = d.orderedSelection
        guard !ids.isEmpty else { return }
        let flat = d.state.layers.flattenedForDisplay(includeCollapsed: true).map { $0.0.id }
        let firstIdx = ids.compactMap { flat.firstIndex(of: $0) }.min() ?? 0
        for id in ids { d.state.removeLayer(id) }
        let remaining = d.state.layers.flattenedForDisplay(includeCollapsed: true).map { $0.0.id }
        d.activeLayerID = remaining.isEmpty ? nil : remaining[min(firstIdx, remaining.count - 1)]
        d.selectedLayerIDs = d.activeLayerID.map { [$0] } ?? []
        d.commit("Delete Layer")
    }

    // MARK: Groups

    static func groupLayers(commit: Bool = true) {
        guard let d = doc else { return }
        // artboards never go into a group (Photoshop disables Group Layers while an artboard is selected)
        guard !selectionHasArtboard(d) else {
            AppModel.shared.setStatus("Artboards can't be grouped: select layers inside or outside the artboards.")
            NSSound.beep()
            return
        }
        let ids = d.orderedSelection
        guard let top = ids.last, let topLayer = d.state.layer(top) else { return }
        _ = topLayer
        // Insert group at the position of the topmost selected layer, in its parent
        var children: [Layer] = []
        let placeholder = Layer(name: "__placeholder__", content: .group(GroupContent()))
        d.state.insertLayer(placeholder, above: top)
        for id in ids { if let l = d.state.removeLayer(id) { children.append(l) } }
        // Layers clipped to a base that stays outside: the group takes over the clipping (as in Photoshop).
        var clipped = false
        for i in children.indices {
            guard children[i].isClipped else { break }
            children[i].isClipped = false
            clipped = true
        }
        var g = Layer(name: d.nextLayerName("Group"), content: .group(GroupContent(children: children, isExpanded: true)))
        g.isClipped = clipped
        g.id = placeholder.id
        d.updateLayer(placeholder.id) { $0 = g }
        d.activeLayerID = g.id
        d.selectedLayerIDs = [g.id]
        if commit { d.commit("Group Layers") }
    }

    static func ungroupLayers() {
        guard let d = doc, let id = d.activeLayerID, let g = d.state.layer(id), g.isGroup else { return }
        var children = g.children
        if g.isClipped { for i in children.indices { children[i].isClipped = true } }   // the group was in a clipping stack: its layers stay in it
        for c in children { d.state.insertLayer(c, below: id) }
        d.state.removeLayer(id)
        d.selectedLayerIDs = Set(children.map(\.id))
        d.activeLayerID = children.last?.id
        d.commit("Ungroup Layers")
    }

    // MARK: Merge / rasterize

    static func mergeDown() {
        guard let d = doc, let id = d.activeLayerID else { return }
        if d.selectedLayerIDs.count > 1 { mergeLayers(d.orderedSelection); return }
        let sib = d.state.siblings(of: id)
        guard let i = sib.firstIndex(where: { $0.id == id }), i > 0 else { NSSound.beep(); return }
        mergeLayers([sib[i - 1].id, id])
    }

    /// Merges layers (bottom-first IDs, same parent) into one raster layer.
    static func mergeLayers(_ ids: [UUID]) {
        guard let d = doc, ids.count >= 1 else { return }
        let ids = d.withoutDescendants(ids)
        let sp = space(d)
        let layers = ids.compactMap { d.state.layer($0) }
        guard let bottom = layers.first, let top = layers.last else { return }
        let img = Compositor.shared.composite(layers: layers, backdrop: CIImage.clearImage.cropped(to: sp.ciCanvas), space: sp, options: .init(globalLight: d.state.globalLight))
        var rect = d.state.canvasRect
        for l in layers { if let b = Compositor.shared.contentBounds(l, state: d.state) { rect = rect.union(IRect(enclosing: b.insetBy(dx: -CGFloat(l.effects.extent), dy: -CGFloat(l.effects.extent)))) } }
        let clamped = rect.intersection(IRect(x: -d.state.width, y: -d.state.height, width: d.state.width * 3, height: d.state.height * 3))
        let buf = RenderEngine.renderBuffer(img, docRect: clamped, space: sp)
        var merged = Layer.raster(name: bottom.isRaster ? bottom.name : top.name, buffer: buf, origin: clamped.origin)
        merged.isVisible = true
        d.state.insertLayer(merged, above: top.id)
        for id in ids { d.state.removeLayer(id) }
        d.activeLayerID = merged.id
        d.selectedLayerIDs = [merged.id]
        d.commit(ids.count == 2 ? "Merge Down" : "Merge Layers")
    }

    static func mergeVisible() {
        ActionRecorder.record(.mergeVisible)
        guard let d = doc else { return }
        let sp = space(d)
        let img = Compositor.shared.composite(d.state)
        let buf = RenderEngine.renderBuffer(img, docRect: d.state.canvasRect, space: sp)
        // Hidden layers survive the merge wherever they are: a visible group keeps its hidden layers (and nothing else).
        func hiddenOnly(_ layers: [Layer]) -> [Layer] {
            layers.compactMap { l in
                if !l.isVisible { return l }
                guard l.isGroup else { return nil }
                let kept = hiddenOnly(l.children)
                if kept.isEmpty { return nil }
                var g = l
                g.children = kept
                return g
            }
        }
        let hidden = hiddenOnly(d.state.layers)
        let merged = Layer.raster(name: "Merged", buffer: buf)
        d.state.layers = hidden + [merged]
        d.activeLayerID = merged.id
        d.selectedLayerIDs = [merged.id]
        d.commit("Merge Visible")
    }

    static func stampVisible() {
        guard let d = doc else { return }
        let sp = space(d)
        let buf = RenderEngine.renderBuffer(Compositor.shared.composite(d.state), docRect: d.state.canvasRect, space: sp)
        d.addLayer(Layer.raster(name: "Stamp Visible", buffer: buf), commitName: "Stamp Visible")
    }

    static func rasterizeLayer(_ id: UUID? = nil) {
        guard let d = doc, let lid = id ?? d.activeLayerID, let l = d.state.layer(lid) else { return }
        guard !l.isRaster, !l.isAdjustment else { return }
        let r = Compositor.shared.rasterize(l, state: d.state, includeEffects: false)
        let bounds = r.buffer.opaqueBounds() ?? IRect(x: 0, y: 0, width: 1, height: 1)
        let trimmed = RasterContent(buffer: r.buffer.cropped(to: bounds), origin: IPoint(x: r.origin.x + bounds.x, y: r.origin.y + bounds.y))
        d.updateLayer(lid) { layer in
            layer.content = .raster(trimmed)   // fill opacity, style and masks stay on the layer
            if layer.blendMode == .passThrough { layer.blendMode = .normal }
        }
        d.commit("Rasterize Layer")
    }

    /// Layer ▸ Rasterize ▸ Layer Style: the style, fill opacity and masks are merged into the pixels (as in Photoshop).
    static func rasterizeLayerStyle() {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id), !l.isAdjustment else { return }
        let r = Compositor.shared.rasterize(l, state: d.state, includeEffects: true, applyMasks: true)
        let bounds = r.buffer.opaqueBounds() ?? IRect(x: 0, y: 0, width: 1, height: 1)
        let trimmed = RasterContent(buffer: r.buffer.cropped(to: bounds), origin: IPoint(x: r.origin.x + bounds.x, y: r.origin.y + bounds.y))
        d.updateLayer(id) { layer in
            layer.content = .raster(trimmed)
            layer.effects = LayerEffects()
            layer.fillOpacity = 1
            layer.mask = nil
            layer.vectorMask = nil
            if layer.blendMode == .passThrough { layer.blendMode = .normal }
        }
        if d.editTarget == .mask { d.editTarget = .content }
        d.commit("Rasterize Layer Style")
    }

    // MARK: Smart objects

    /// Content bounds of the selected layers (nil: nothing to put in a smart object, e.g. adjustment layers, empty groups,
    /// a type layer with no text yet — its layout box would make an invisible smart object).
    private static func smartObjectSourceBounds(_ d: Document) -> CGRect? {
        var u: CGRect? = nil
        for id in d.withoutDescendants(d.orderedSelection) {
            guard let l = d.state.layer(id), !(l.text.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false) else { continue }
            if let b = Compositor.shared.contentBounds(l, state: d.state) { u = u.map { $0.union(b) } ?? b }
        }
        return u
    }

    /// Layer ▸ Smart Objects ▸ Convert / Filter ▸ Convert for Smart Filters has something to convert.
    static var canConvertToSmartObject: Bool { doc.map { smartObjectSourceBounds($0) != nil } ?? false }

    static func convertToSmartObject() {
        guard let d = doc else { return }
        let ids = d.withoutDescendants(d.orderedSelection)
        guard !ids.isEmpty else { return }
        let layers = ids.compactMap { d.state.layer($0) }
        guard let b0 = smartObjectSourceBounds(d) else { NSSound.beep(); return }
        func fxExtent(_ l: Layer) -> Double { max(l.effects.enabled ? l.effects.extent : 0, l.children.map(fxExtent).max() ?? 0) }
        let maxFx = layers.map(fxExtent).max() ?? 0
        let b = IRect(enclosing: b0.insetBy(dx: -CGFloat(maxFx), dy: -CGFloat(maxFx)))
        var inner = DocumentState(width: max(1, b.width), height: max(1, b.height), resolution: d.state.resolution)
        inner.globalLight = d.state.globalLight          // effects inside keep their light angle
        // Layers clipped to a base outside the selection: the smart object takes over the clipping.
        var leading = true, clipped = false
        inner.layers = layers.map { src in
            var l = src
            l.translate(dx: Double(-b.x), dy: Double(-b.y), document: true)   // unlinked masks move along too
            if leading && l.isClipped { l.isClipped = false; clipped = true } else { leading = false }
            return l
        }
        let name = layers.count == 1 ? layers[0].name : "Smart Object"
        let so = SmartObjectContent(source: .document(inner), quad: Quad(rect: b.cgRect), sourceName: name)
        var newLayer = Layer(name: name, content: .smartObject(so))
        newLayer.isClipped = clipped
        if layers.count == 1 {
            // A single layer hands its blending over to the smart object (inside, it would only see transparency).
            let src = layers[0]
            newLayer.isVisible = src.isVisible
            newLayer.opacity = src.opacity
            newLayer.colorLabel = src.colorLabel
            newLayer.linkID = src.linkID
            newLayer.blendIf = src.blendIf
            newLayer.channelR = src.channelR; newLayer.channelG = src.channelG; newLayer.channelB = src.channelB
            if src.blendMode != .passThrough { newLayer.blendMode = src.blendMode }
            let plain = !(src.effects.enabled && src.effects.hasAny)
            if plain { newLayer.fillOpacity = src.fillOpacity; newLayer.knockout = src.knockout }
            inner.layers[0].isVisible = true
            inner.layers[0].opacity = 1
            inner.layers[0].colorLabel = .none
            inner.layers[0].linkID = nil
            inner.layers[0].blendIf = BlendIf()
            inner.layers[0].channelR = true; inner.layers[0].channelG = true; inner.layers[0].channelB = true
            if src.blendMode != .passThrough { inner.layers[0].blendMode = .normal }
            if plain { inner.layers[0].fillOpacity = 1; inner.layers[0].knockout = .none }
            if case .smartObject(var s) = newLayer.content { s.source = .document(inner); newLayer.content = .smartObject(s) }
        }
        d.state.insertLayer(newLayer, above: ids.last!)
        for id in ids { d.state.removeLayer(id) }
        d.activeLayerID = newLayer.id
        d.selectedLayerIDs = [newLayer.id]
        d.commit("Convert to Smart Object")
    }

    static func replaceSmartContents() {
        guard let d = doc, let id = d.activeLayerID, d.state.layer(id)?.isSmartObject == true else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = openTypes + DocumentIO.extraOpenTypes
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url else { return }
            replaceSmartContents(of: id, in: d, with: url)
        }
    }

    /// Layer ▸ Smart Objects ▸ Replace Contents with the file at `url`. Contents of another size fit the current box
    /// or keep the object's scale, per the layer's setting (Properties panel) or `fit`.
    @discardableResult
    static func replaceSmartContents(of id: UUID, in d: Document, with url: URL, fit: SmartContentFit? = nil) -> Bool {
        guard d.state.layer(id)?.isSmartObject == true, let placed = try? DocumentIO.loadForPlacing(url: url) else { return false }
        d.updateLayer(id) { l in
            guard var so = l.smart else { return }
            if placed.state.layers.count == 1, let rr = placed.state.layers[0].raster { so.replaceSource(.image(rr.buffer), fit: fit) } else { so.replaceSource(.document(placed.state), fit: fit) }
            l.smart = so
        }
        d.commit("Replace Contents")
        return true
    }

    static func exportSmartContents() {
        guard let d = doc, let l = d.activeLayer, let so = l.smart else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = so.sourceName + ".png"
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url else { return }
            let st: DocumentState
            switch so.source {
            case .document(let s): st = s
            case .image(let b): var s = DocumentState(width: b.width, height: b.height); s.layers = [Layer.raster(name: "L", buffer: b)]; st = s
            }
            try? DocumentIO.export(st, to: url, format: .png, quality: 1, scale: 1)
        }
    }

    // MARK: Masks

    static func addMask(_ kind: MaskInit) {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id) else { return }
        if l.mask != nil { NSSound.beep(); return }
        let W = d.state.width, H = d.state.height
        var m: LayerMask
        switch kind {
        case .revealAll: m = .reveal(width: W, height: H)
        case .hideAll: m = .hide(width: W, height: H)
        case .revealSelection:
            guard let s = d.state.selection else { m = .reveal(width: W, height: H); break }
            m = LayerMask(buffer: s.copy(), origin: .zero, outsideValue: 0)
        case .hideSelection:
            guard let s = d.state.selection else { m = .hide(width: W, height: H); break }
            m = LayerMask(buffer: SelectionOps.invert(s), origin: .zero, outsideValue: 255)
        case .fromTransparency:
            guard let r = l.raster else { m = .reveal(width: W, height: H); break }
            m = LayerMask(buffer: SelectionOps.fromAlpha(r.buffer, origin: r.origin, width: W, height: H), origin: .zero, outsideValue: 0)
        }
        d.updateLayer(id) { $0.mask = m }
        d.editTarget = .mask
        if kind == .revealSelection || kind == .hideSelection { d.state.selection = nil }
        d.commit("Add Layer Mask")
    }

    static func deleteMask() {
        guard let d = doc, let id = d.activeLayerID, d.state.layer(id)?.mask != nil else { return }   // no mask: no empty history step
        d.updateLayer(id) { $0.mask = nil }
        d.editTarget = .content
        d.commit("Delete Layer Mask")
    }

    static func applyMask() {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id), l.mask != nil else { return }
        if !l.isRaster { offerRasterize(layer: id); return }
        let sp = space(d)
        var tmp = l
        tmp.effects = LayerEffects()
        tmp.opacity = 1
        tmp.fillOpacity = 1
        tmp.blendMode = .normal
        tmp.vectorMask = nil
        tmp.isVisible = true          // a hidden layer keeps its pixels
        let img = Compositor.shared.layerAppearance(tmp, state: d.state)
        let r = l.raster!
        let buf = RenderEngine.renderBuffer(img, docRect: r.frame, space: sp)
        d.updateLayer(id) { layer in
            layer.raster = RasterContent(buffer: buf, origin: r.origin)
            layer.mask = nil
        }
        d.editTarget = .content
        d.commit("Apply Layer Mask")
    }

    static func toggleMaskEnabled() {
        guard let d = doc, let id = d.activeLayerID, d.state.layer(id)?.mask != nil else { return }
        d.updateLayer(id) { $0.mask?.isEnabled.toggle() }
        d.commit("Toggle Layer Mask")
    }

    static func invertMask() {
        guard let d = doc, let id = d.activeLayerID, let m = d.state.layer(id)?.mask else { return }
        d.updateLayer(id) { l in
            l.mask?.buffer = SelectionOps.invert(m.buffer)
            l.mask?.outsideValue = 255 - m.outsideValue
        }
        d.commit("Invert Mask")
    }

    static func addVectorMask() {
        guard let d = doc, let id = d.activeLayerID else { return }
        var p = VectorPath.rect(d.state.canvasCGRect)
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }) { p = np.path }
        d.updateLayer(id) { $0.vectorMask = p }
        d.commit("Add Vector Mask")
    }

    // MARK: Clipping, arrange, locks

    static func toggleClippingMask() {
        guard let d = doc else { return }
        for id in d.orderedSelection { d.updateLayer(id) { $0.isClipped.toggle() } }
        d.commit("Clipping Mask")
    }

    enum Arrange { case front, forward, backward, back }

    static func arrange(_ a: Arrange) {
        guard let d = doc, let id = d.activeLayerID, var path = d.state.layers.indexPath(of: id) else { return }
        let sib = d.state.siblings(of: id)
        let i = path.last!
        var j = i
        switch a {
        case .front: j = sib.count - 1
        case .forward: j = min(sib.count - 1, i + 1)
        case .backward: j = max(0, i - 1)
        case .back: j = 0
        }
        guard j != i else { return }
        let l = d.state.layers.remove(at: path)
        path[path.count - 1] = j
        d.state.layers.insert(l, at: path)
        d.commit("Arrange")
    }

    /// Moves a layer relative to another (drag & drop in the layers panel).
    static func moveLayer(_ id: UUID, relativeTo target: UUID, above: Bool, into: Bool = false) {
        guard let d = doc, id != target, let l = d.state.layer(id) else { return }
        // Don't allow moving a group into itself
        if l.allIDs.contains(target) { return }
        d.state.removeLayer(id)
        if into {
            d.state.insertLayer(l, above: target, inside: true)
        } else if above {
            d.state.insertLayer(l, above: target)
        } else {
            d.state.insertLayer(l, below: target)
        }
        d.commit("Move Layer")
    }

    /// Selected layers whose blend mode / opacity / fill may change (Lock All excludes a layer).
    static func blendingEditable(_ d: Document) -> [UUID] {
        d.orderedSelection.filter { d.state.layer($0).map { !$0.locks.propertiesLocked } ?? false }
    }

    /// Changes blend mode / opacity / fill of the selected layers that aren't locked. Every control that edits these
    /// goes through here, so Lock All holds whichever one is used. Returns false when nothing could change.
    @discardableResult
    static func setBlending(_ d: Document, _ body: (inout Layer) -> Void) -> Bool {
        let ids = blendingEditable(d)
        for id in ids { d.updateLayer(id, body) }
        return !ids.isEmpty
    }

    static func setLock(_ keyPath: WritableKeyPath<LayerLocks, Bool>) {
        guard let d = doc, let id = d.activeLayerID else { return }
        d.updateLayer(id) { $0.locks[keyPath: keyPath].toggle() }
        d.commit("Lock")
    }

    // MARK: Align / distribute

    static func align(_ mode: AlignMode) {
        guard let d = doc else { return }
        let ids = d.withoutDescendants(d.orderedSelection).filter { d.state.layer($0)?.locks.positionLocked != true }
        var bounds: [UUID: CGRect] = [:]
        for id in ids { if let l = d.state.layer(id), let b = Compositor.shared.contentBounds(l, state: d.state) { bounds[id] = b } }
        guard !bounds.isEmpty else { return }
        let ref: CGRect
        if bounds.count == 1 {
            ref = d.state.selection?.opaqueBounds()?.cgRect ?? d.state.canvasCGRect
        } else {
            ref = bounds.values.reduce(bounds.values.first!) { $0.union($1) }
        }
        for (id, b) in bounds {
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch mode {
            case .left: dx = ref.minX - b.minX
            case .hCenter: dx = ref.midX - b.midX
            case .right: dx = ref.maxX - b.maxX
            case .top: dy = ref.minY - b.minY
            case .vCenter: dy = ref.midY - b.midY
            case .bottom: dy = ref.maxY - b.maxY
            }
            d.updateLayer(id) { $0.translate(dx: Double(dx.rounded()), dy: Double(dy.rounded())) }
        }
        d.commit("Align")
    }

    static func distribute(horizontal: Bool) {
        guard let d = doc else { return }
        var items: [(UUID, CGRect)] = []
        for id in d.withoutDescendants(d.orderedSelection) { if let l = d.state.layer(id), !l.locks.positionLocked, let b = Compositor.shared.contentBounds(l, state: d.state) { items.append((id, b)) } }
        guard items.count >= 3 else { NSSound.beep(); return }
        items.sort { horizontal ? $0.1.midX < $1.1.midX : $0.1.midY < $1.1.midY }
        let first = horizontal ? items.first!.1.midX : items.first!.1.midY
        let last = horizontal ? items.last!.1.midX : items.last!.1.midY
        let step = (last - first) / CGFloat(items.count - 1)
        for (i, (id, b)) in items.enumerated() {
            let target = first + step * CGFloat(i)
            let delta = target - (horizontal ? b.midX : b.midY)
            d.updateLayer(id) { $0.translate(dx: horizontal ? Double(delta.rounded()) : 0, dy: horizontal ? 0 : Double(delta.rounded())) }
        }
        d.commit("Distribute")
    }

    // MARK: Layer style clipboard

    static var copiedEffects: LayerEffects?

    static func copyLayerStyle() { copiedEffects = doc?.activeLayer?.effects }

    static func pasteLayerStyle() {
        guard let d = doc, let fx = copiedEffects else { return }
        for id in d.orderedSelection { d.updateLayer(id) { $0.effects = fx } }
        d.commit("Paste Layer Style")
    }

    static func clearLayerStyle() {
        guard let d = doc else { return }
        // (hidden effects are part of the style too: `hasStyle`, not `hasAny`)
        guard d.orderedSelection.contains(where: { d.state.layer($0)?.effects.hasStyle ?? false }) else { return }   // no style: no empty history step
        for id in d.orderedSelection { d.updateLayer(id) { $0.effects = LayerEffects() } }
        d.commit("Clear Layer Style")
    }

    // MARK: Type

    static func convertTextToShape() {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id), let t = l.text else { return }
        let outline = TextRenderer.outlinePath(t)
        // Colour emoji are bitmaps: they have no outlines to convert, and a shape has one fill colour.
        let emoji = TextRenderer.hasColorGlyphs(t)
        if emoji, outline.boundingBoxOfPath.isEmpty {
            app.setStatus("Colour emoji have no outlines, so they can't become a shape. Use Rasterize Layer to keep them as pixels.")
            NSSound.beep()
            return
        }
        let vp = VectorPath.from(cgPath: outline)
        var s = ShapeContent(geometry: .path(vp), fill: .color(t.color))
        s.stroke.paint = .none
        d.updateLayer(id) { $0.content = .shape(s) }
        if emoji {
            // the emoji stay where they were, as pixels on a layer above the shape (with the layer's look)
            let sp = space(d)
            let img = TextRenderer.render(t, space: sp, only: TextRenderer.isColorRun)
            let r = IRect(enclosing: sp.docRect(img.extent)).intersection(d.state.canvasRect)
            if !r.isEmpty {
                var px = Layer.raster(name: l.name + " emoji", buffer: RenderEngine.renderBuffer(img, docRect: r, space: sp), origin: r.origin)
                px.opacity = l.opacity; px.fillOpacity = l.fillOpacity; px.blendMode = l.blendMode; px.effects = l.effects
                d.state.insertLayer(px, above: id)
            }
            app.setStatus("Colour emoji have no outlines: they were kept as pixels on the layer above the shape.")
        }
        d.commit("Convert to Shape")
    }

    static func createWorkPathFromText() {
        guard let d = doc, let t = d.activeLayer?.text else { return }
        _ = VectorEditing.newWorkPath(d, VectorPath.from(cgPath: TextRenderer.outlinePath(t)), addToActive: false)
        d.commit("Create Work Path")
    }

    // MARK: Selection from layer

    static func selectLayerPixels(_ id: UUID? = nil, mode: SelectionCombine = .new) {
        guard let d = doc, let lid = id ?? d.activeLayerID, let l = d.state.layer(lid) else { return }
        let sp = space(d)
        guard let img = Compositor.shared.contentImage(l, space: sp) else { return }
        let alpha = img.alphaAsGray.cropped(to: sp.ciCanvas).composited(over: CIImage.color(.black, sp.ciCanvas))
        let m = RenderEngine.renderBuffer(alpha, docRect: d.state.canvasRect, space: sp, format: .gray)
        d.setSelection(SelectionOps.combine(d.state.selection, m, mode: mode), commitName: "Load Selection")
    }
}
