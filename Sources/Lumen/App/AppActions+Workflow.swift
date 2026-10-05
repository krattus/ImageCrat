import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Linked layers

extension AppActions {
    /// Links the selected layers (or unlinks them if they already share a link).
    static func toggleLinkLayers() {
        guard let d = doc else { return }
        let ids = d.orderedSelection
        guard !ids.isEmpty else { Beep.play(); return }
        let links = Set(ids.map { d.state.layer($0)?.linkID })
        if ids.count == 1, d.state.layer(ids[0])?.linkID == nil { Beep.play(); return }   // one unlinked layer: nothing to link or unlink
        if ids.count == 1 || (links.count == 1 && links.first! != nil) {
            for id in ids { d.updateLayer(id) { $0.linkID = nil } }
            d.commit("Unlink Layers")
        } else {
            let link = UUID()
            for id in ids { d.updateLayer(id) { $0.linkID = link } }
            d.commit("Link Layers")
        }
    }

    static func selectLinkedLayers() {
        guard let d = doc else { return }
        let ids = d.withLinked(d.orderedSelection)
        d.selectedLayerIDs = Set(ids)
    }
}

// MARK: - Artboards

extension AppActions {
    static func artboards(_ d: Document) -> [Layer] { d.state.allLayers.filter { $0.isArtboard } }

    /// True when the layer selection includes an artboard (Group Layers is disabled then: artboards stay top-level).
    static func selectionHasArtboard(_ d: Document) -> Bool {
        d.orderedSelection.contains { d.state.layer($0)?.isArtboard == true }
    }

    /// Layer ▸ Group Layers is available (a selection without artboards).
    static var canGroupLayers: Bool { doc.map { !$0.orderedSelection.isEmpty && !selectionHasArtboard($0) } ?? false }

    /// Adds an artboard of `size` to the right of existing artboards (the first one covers the canvas and takes the
    /// layers it covers — see `ArtboardActions.newArtboard`).
    static func newArtboard(size: CGSize? = nil, preset: String? = nil) {
        guard let d = doc else { return }
        ArtboardActions.newArtboard(d, size: size, preset: preset ?? size.flatMap { s in Artboard.presets.first { $0.1 == s }?.0 })
    }

    /// Turns the selected layers into an artboard fitted to their bounds.
    static func artboardFromLayers() {
        guard let d = doc, !d.orderedSelection.isEmpty else { Beep.play(); return }
        // artboards can't go into another artboard: they stay where they are
        let picked = d.withoutDescendants(d.orderedSelection).filter { d.state.layer($0)?.isArtboard == false }
        guard !picked.isEmpty else { Beep.play(); return }
        d.selectedLayerIDs = Set(picked)
        if let a = d.activeLayerID, !picked.contains(a) { d.activeLayerID = picked.last }
        var b: CGRect?
        for id in d.orderedSelection {
            if let l = d.state.layer(id), let r = Compositor.shared.contentBounds(l, state: d.state) { b = b.map { $0.union(r) } ?? r }
        }
        groupLayers(commit: false)                       // one history step for the whole command
        guard let gid = d.activeLayerID else { return }
        let rect = (b ?? d.state.canvasCGRect).integral
        let name = ArtboardOps.nextName(d.state)   // read before the update: the closure has exclusive access to the state
        d.updateLayer(gid) { l in
            guard case .group(var g) = l.content else { return }
            g.artboard = Artboard(rect: rect)
            l.content = .group(g)
            l.blendMode = .normal
            l.name = name
        }
        d.commit("Artboard from Layers")
    }

    static func convertArtboardToGroup() {
        guard let d = doc, let id = d.activeLayerID, d.state.layer(id)?.isArtboard == true else { return }
        ArtboardActions.convertToGroup(d, [id])
    }

    /// Enlarges the canvas (anchored top-left) so `rect` fits; content keeps its doc coordinates.
    static func growCanvas(_ d: Document, toInclude rect: CGRect) {
        let need = d.state.canvasCGRect.union(rect)
        guard need != d.state.canvasCGRect, need.minX.isFinite, need.minY.isFinite, need.width.isFinite, need.height.isFinite else { return }
        let lim = CGFloat(maxCanvasDimension)
        let dx = max(0, -Int(floor(max(-lim, need.minX)))), dy = max(0, -Int(floor(max(-lim, need.minY))))
        let w = Int(ceil(min(lim, need.width))), h = Int(ceil(min(lim, need.height)))
        var st = d.state
        if dx > 0 || dy > 0 {
            for i in st.layers.indices { st.layers[i].translate(dx: Double(dx), dy: Double(dy), document: true) }
            syncStoredGeometry(from: d.state, to: &st, dx: Double(dx), dy: Double(dy))
        }
        func grow(_ b: PixelBuffer) -> PixelBuffer {
            let n = PixelBuffer(width: w, height: h, format: .gray)
            n.copyPixels(from: b, at: IPoint(x: dx, y: dy))
            n.markDirty()
            return n
        }
        if let s = st.selection { st.selection = grow(s) }
        st.alphaChannels = st.alphaChannels.map { var c = $0; c.buffer = grow(c.buffer); return c }
        if dx > 0 || dy > 0 {
            // everything positioned in document coordinates moves with the layers
            st.paths = st.paths.map { var p = $0; p.path = p.path.applying(CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))); return p }
            st.guides = st.guides.map { var g = $0; g.position += g.isVertical ? Double(dx) : Double(dy); return g }
            st.toolData = st.toolData.mapped { CGPoint(x: $0.x + CGFloat(dx), y: $0.y + CGFloat(dy)) }
        }
        st.width = w
        st.height = h
        d.state = st
        d.needsFitOnScreen = true
    }

    /// A standalone document state containing only the artboard, cropped to its bounds.
    static func artboardState(_ st: DocumentState, _ layer: Layer) -> DocumentState? {
        guard let ab = layer.artboard else { return nil }
        let r = ab.rect.integral
        var out = st
        var l = layer
        l.translate(dx: -Double(r.minX), dy: -Double(r.minY), document: true)
        out.layers = [l]
        out.width = Int(r.width)
        out.height = Int(r.height)
        out.selection = nil
        out.alphaChannels = []
        out.guides = []
        return out
    }

    /// File ▸ Export ▸ Artboards to Files… (the options dialog; see `ArtboardExport`).
    static func exportArtboards() {
        guard let d = doc else { return }
        guard !artboards(d).isEmpty else { alert("This document has no artboards."); return }
        DialogRegistry.show("artboardsToFiles")
    }
}

// MARK: - Layer comps

extension AppActions {
    /// Reference point that moves 1:1 with `Layer.translate`. Groups move through their children; what a group owns
    /// itself (artboard frame, masks) and layers without pixels (fill / adjustment: their masks) are anchored too.
    static func anchor(_ l: Layer, _ st: DocumentState) -> CGPoint? {
        func own() -> CGPoint? {
            if let m = l.mask, m.isLinked { return m.origin.cgPoint }
            if let vm = l.vectorMask, !vm.isEmpty { return vm.bounds.origin }
            return nil
        }
        switch l.content {
        case .group(let g): return g.artboard?.rect.origin ?? own()
        case .adjustment: return own()
        case .fill(let f):
            if case .gradient(let g) = f.paint, let s = g.start, g.end != nil { return s }
            return own()
        default: return Compositor.shared.contentBounds(l, state: st)?.origin
        }
    }

    static func captureComp(name: String, visibility: Bool = true, position: Bool = true, appearance: Bool = true) -> LayerComp {
        var comp = LayerComp(name: name, useVisibility: visibility, usePosition: position, useAppearance: appearance)
        guard let d = doc else { return comp }
        for l in d.state.allLayers {
            comp.entries[l.id] = LayerCompEntry(visible: l.isVisible, position: anchor(l, d.state), opacity: l.opacity,
                                                fillOpacity: l.fillOpacity, blendMode: l.blendMode, effects: l.effects)
        }
        return comp
    }

    static func newLayerComp() {
        guard let d = doc else { return }
        let c = captureComp(name: "Layer Comp \(d.state.layerComps.count + 1)")
        d.state.layerComps.append(c)
        d.activeCompID = c.id
        d.commit("New Layer Comp")
    }

    static func updateLayerComp(_ id: UUID) {
        guard let d = doc, let i = d.state.layerComps.firstIndex(where: { $0.id == id }) else { return }
        let old = d.state.layerComps[i]
        var c = captureComp(name: old.name, visibility: old.useVisibility, position: old.usePosition, appearance: old.useAppearance)
        c.id = old.id
        c.comment = old.comment
        d.state.layerComps[i] = c
        d.commit("Update Layer Comp")
    }

    static func applyLayerComp(_ id: UUID, commit: Bool = true) {
        guard let d = doc, let comp = d.state.layerComps.first(where: { $0.id == id }) else { return }
        var st = d.state
        applyComp(comp, to: &st)
        d.state = st
        d.activeCompID = id
        if commit { d.commit("Apply Layer Comp") }
    }

    static func applyComp(_ comp: LayerComp, to st: inout DocumentState) {
        for id in st.allLayers.map(\.id) {   // groups first: moving one takes its children along, which then only fix their own offset
            guard let e = comp.entries[id], let l = st.layer(id) else { continue }
            let current = anchor(l, st)
            st.updateLayer(id) { x in
                if comp.useVisibility { x.isVisible = e.visible }
                if comp.useAppearance {
                    x.opacity = e.opacity; x.fillOpacity = e.fillOpacity; x.blendMode = e.blendMode; x.effects = e.effects
                }
                if comp.usePosition, let p = e.position, let c = current, p != c {
                    x.translate(dx: Double(p.x - c.x), dy: Double(p.y - c.y))
                }
            }
        }
    }

    static func stepLayerComp(_ delta: Int) {
        guard let d = doc, !d.state.layerComps.isEmpty else { return }
        let i = d.state.layerComps.firstIndex { $0.id == d.activeCompID } ?? -1
        let n = (i + delta + d.state.layerComps.count) % d.state.layerComps.count
        applyLayerComp(d.state.layerComps[n].id)
    }

    static func exportLayerCompsToFiles() {
        guard let d = doc, !d.state.layerComps.isEmpty else { alert("This document has no layer comps."); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard UIBlock.run(panel) == .OK, let dir = panel.url else { return }
        for c in d.state.layerComps {
            var st = d.state
            applyComp(c, to: &st)
            try? DocumentIO.export(st, to: dir.appendingPathComponent(c.name.replacingOccurrences(of: "/", with: "-") + ".png"), format: .png, quality: 1, scale: 1)
        }
        app.setStatus("Exported \(d.state.layerComps.count) layer comps.")
    }
}

struct LayerCompsPanel: View {
    @Bindable var app = AppModel.shared
    @State private var renaming: UUID?
    @State private var nameText = ""

    var body: some View {
        if let d = app.activeDocument {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        row(nil, d)
                        ForEach(d.state.layerComps) { c in row(c, d) }
                    }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 4) {
                    IconButton(symbol: "backward.end", help: "Apply previous comp", size: 22) { AppActions.stepLayerComp(-1) }
                    IconButton(symbol: "forward.end", help: "Apply next comp", size: 22) { AppActions.stepLayerComp(1) }
                    Spacer()
                    IconButton(symbol: "arrow.triangle.2.circlepath", help: "Update comp from current state", size: 22) {
                        if let id = d.activeCompID { AppActions.updateLayerComp(id) }
                    }.disabled(d.activeCompID == nil)
                    IconButton(symbol: "square.and.arrow.up", help: "Export comps to files", size: 22) { AppActions.exportLayerCompsToFiles() }
                    IconButton(symbol: "plus.square", help: "New layer comp", size: 22) { AppActions.newLayerComp() }
                    IconButton(symbol: "trash", help: "Delete layer comp", size: 22) {
                        d.state.layerComps.removeAll { $0.id == d.activeCompID }
                        d.activeCompID = nil
                        d.commit("Delete Layer Comp")
                    }.disabled(d.activeCompID == nil)
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .background(Theme.panelHeader)
            }
            .font(Theme.font)
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder func row(_ c: LayerComp?, _ d: Document) -> some View {
        let active = c?.id == d.activeCompID
        HStack(spacing: 6) {
            Image(systemName: active ? "checkmark.square.fill" : "square").foregroundStyle(active ? Theme.accent : Theme.textFaint)
                .onTapGesture { if let c { AppActions.applyLayerComp(c.id) } }
            if let c, renaming == c.id {
                TextField("", text: $nameText).textFieldStyle(.plain).onSubmit {
                    if let i = d.state.layerComps.firstIndex(where: { $0.id == c.id }), !nameText.isEmpty { d.state.layerComps[i].name = nameText; d.commit("Rename Layer Comp") }
                    renaming = nil
                }
            } else {
                Text(c?.name ?? "Last Document State").foregroundStyle(c == nil ? Theme.textDim : Theme.text).lineLimit(1)
            }
            Spacer()
            if let c {
                HStack(spacing: 2) {
                    toggle(c, d, "eye", \.useVisibility, "Visibility")
                    toggle(c, d, "arrow.up.and.down.and.arrow.left.and.right", \.usePosition, "Position")
                    toggle(c, d, "fx", \.useAppearance, "Appearance (layer style)")
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(active ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { if let c { renaming = c.id; nameText = c.name } })
        .simultaneousGesture(TapGesture().onEnded {
            if let c { AppActions.applyLayerComp(c.id) } else { d.activeCompID = nil }
        })
    }

    func toggle(_ c: LayerComp, _ d: Document, _ symbol: String, _ kp: WritableKeyPath<LayerComp, Bool>, _ help: String) -> some View {
        let on = c[keyPath: kp]
        return Image(systemName: symbol).font(.system(size: 9))
            .foregroundStyle(on ? Theme.text : Theme.textFaint.opacity(0.5))
            .frame(width: 16, height: 16)
            .help(help + (on ? " (captured)" : " (ignored)"))
            .onTapGesture {
                if let i = d.state.layerComps.firstIndex(where: { $0.id == c.id }) { d.state.layerComps[i][keyPath: kp].toggle(); d.commit("Layer Comp Options") }
            }
    }
}

// MARK: - Linked smart objects

extension AppActions {
    static func placeLinked() { placePanel(linked: true) }

    static func placeLinked(_ url: URL) {
        guard let d = doc else { return }
        do {
            let placed = try DocumentIO.loadForPlacing(url: url)
            let name = (url.lastPathComponent as NSString).deletingPathExtension
            let src: SmartSource = placed.state.layers.count == 1 && placed.state.layers[0].raster != nil
                ? .image(placed.state.layers[0].raster!.buffer) : .document(placed.state)
            let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
            var w = src.size.width, h = src.size.height
            let s = min(1, min(W / w, H / h))
            w *= s; h *= s
            var so = SmartObjectContent(source: src, quad: Quad(rect: CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)), sourceName: url.lastPathComponent)
            so.linkedURL = url
            so.linkedModified = modificationDate(url)
            d.addLayer(Layer(name: name, content: .smartObject(so)), commitName: "Place Linked")
        } catch {
            alert("Could not place “\(url.lastPathComponent)”.", error.localizedDescription)
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Reloads linked smart objects whose files changed on disk. Returns the number updated.
    @discardableResult
    static func updateModifiedLinkedContent(_ d: Document, all: Bool = false, commit: Bool = true) -> Int {
        var n = 0
        for l in d.state.allLayers {
            guard case .smartObject(let so) = l.content, let url = so.linkedURL else { continue }
            let mod = modificationDate(url)
            guard all || (mod != nil && mod != so.linkedModified) else { continue }
            guard let loaded = try? DocumentIO.loadForPlacing(url: url) else { continue }
            let src: SmartSource = loaded.state.layers.count == 1 && loaded.state.layers[0].raster != nil
                ? .image(loaded.state.layers[0].raster!.buffer) : .document(loaded.state)
            d.updateLayer(l.id) { x in
                guard var s = x.smart else { return }
                s.replaceSource(src)        // a file that changed size fits the box or keeps the scale (layer setting)
                s.linkedModified = mod
                x.smart = s
            }
            n += 1
        }
        if n > 0 && commit { d.commit("Update Linked Content") }
        return n
    }

    static func relinkToFile() {
        guard let d = doc, let id = d.activeLayerID, d.state.layer(id)?.smart != nil else { Beep.play(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = openTypes + DocumentIO.extraOpenTypes
        guard UIBlock.run(panel) == .OK, let url = panel.url else { return }
        relink(id, in: d, to: url)
    }

    /// Layer ▸ Smart Objects ▸ Relink to File: links the layer to `url` and loads it (one history step). A file of
    /// another size fits the current box or keeps the object's scale, per the layer's setting.
    static func relink(_ id: UUID, in d: Document, to url: URL) {
        guard d.state.layer(id)?.smart != nil else { return }
        d.updateLayer(id) { x in
            guard var s = x.smart else { return }
            s.linkedURL = url
            s.linkedModified = nil
            s.sourceName = url.lastPathComponent
            x.smart = s
        }
        updateModifiedLinkedContent(d, all: false, commit: false)
        d.commit("Relink to File")
    }

    static func embedLinked() {
        guard let d = doc, let id = d.activeLayerID, d.state.layer(id)?.smart?.linkedURL != nil else { Beep.play(); return }
        d.updateLayer(id) { x in
            guard var s = x.smart else { return }
            s.linkedURL = nil
            s.linkedModified = nil
            x.smart = s
        }
        d.commit("Embed Linked")
    }

    static func convertToLinked() {
        guard let d = doc, let id = d.activeLayerID, let so = d.state.layer(id)?.smart else { Beep.play(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Brand.documentType]
        panel.nameFieldStringValue = (so.sourceName as NSString).deletingPathExtension + "." + Brand.documentExtension
        guard UIBlock.run(panel) == .OK, let url = panel.url else { return }
        do { try convertToLinked(id, in: d, to: url) } catch { alert("Could not save the linked file.", error.localizedDescription) }
    }

    /// Layer ▸ Smart Objects ▸ Convert to Linked: writes the embedded source to `url` and links the layer to it.
    static func convertToLinked(_ id: UUID, in d: Document, to url: URL) throws {
        guard let so = d.state.layer(id)?.smart else { return }
        let st: DocumentState
        switch so.source {
        case .document(let s): st = s
        case .image(let b):
            var s = DocumentState(width: b.width, height: b.height)
            s.layers = [Layer.raster(name: "Layer 1", buffer: b)]
            st = s
        }
        try DocumentIO.saveNative(Document(state: st, name: url.lastPathComponent), to: url)
        d.updateLayer(id) { x in
            guard var s = x.smart else { return }
            s.linkedURL = url
            s.linkedModified = modificationDate(url)
            s.sourceName = url.lastPathComponent
            x.smart = s
        }
        d.commit("Convert to Linked")
    }
}
