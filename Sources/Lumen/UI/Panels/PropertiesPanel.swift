import SwiftUI
import ImageCratCore

struct PropertiesPanel: View {
    @Bindable var app = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let d = app.activeDocument, let l = d.activeLayer {
                    PropertiesContent(doc: d, layer: l)
                } else if let d = app.activeDocument {
                    DocumentProperties(doc: d)
                } else {
                    Text("No Properties").foregroundStyle(Theme.textFaint)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text)
    }
}

struct DocumentProperties: View {
    @Bindable var doc: Document
    var body: some View {
        Caption("Document")
        Text("\(doc.state.width) × \(doc.state.height) px at \(Int(doc.state.resolution)) ppi")
        WrappingHStack {
            Button("Image Size…") { AppModel.shared.dialog = .imageSize }.buttonStyle(PanelButtonStyle())
            Button("Canvas Size…") { AppModel.shared.dialog = .canvasSize }.buttonStyle(PanelButtonStyle())
        }
    }
}

struct PropertiesContent: View {
    @Bindable var doc: Document
    let layer: Layer

    func live(_ body: @escaping (inout Layer) -> Void) { doc.updateLayer(layer.id, body) }
    func commit(_ n: String = "Properties") { doc.commit(n) }

    var body: some View {
        HStack {
            Text(tr(layer.kindName)).font(Theme.fontBold)
            Spacer()
            Text(layer.name).foregroundStyle(Theme.textDim).lineLimit(1)
        }
        GenerativeLayerProperties(doc: doc, layerID: layer.id)
        ComponentInstanceProperties(doc: doc, layerID: layer.id)
        RecipeLayerProperties(doc: doc, layerID: layer.id)   // Recipe layers / Recipe smart filters (Nodes module)
        ArtistLayerProperties(doc: doc, layer: layer)   // global colour links, text contrast badge
        if doc.editTarget == .mask, let m = layer.mask {
            maskProperties(m)
        } else {
            switch layer.content {
            case .adjustment(let a):
                AdjustmentControls(s: Binding(get: { a }, set: { v in live { $0.adjustment = v } }), doc: doc, onCommit: { commit(a.kind.displayName) })
                Divider()
                WrappingHStack {
                    Button("Reset") { live { $0.adjustment = AdjustmentSettings(kind: a.kind) }; commit() }.buttonStyle(PanelButtonStyle())
                    Button(tr(layer.isClipped ? "Unclip" : "Clip to Layer")) { live { $0.isClipped.toggle() }; commit("Clipping Mask") }.buttonStyle(PanelButtonStyle())
                }
            case .text(let t):
                TextProperties(t: Binding(get: { t }, set: { v in live { $0.text = v } }), onCommit: { commit("Edit Type") })
            case .shape(let s):
                ShapeProperties(s: Binding(get: { s }, set: { v in live { $0.shape = v } }), onCommit: { commit("Edit Shape") },
                                origin: ArtboardCoords.layerOrigin(layer.id, doc.state))
                if layer.vectorMask != nil {
                    Button("Intersect Shape with Vector Mask") { ShapeMaskOps.intersectWithVectorMask(doc, layer.id) }
                        .buttonStyle(PanelButtonStyle())
                        .help("Makes the masked outline the shape itself, so its stroke runs along the cut edge too (the vector mask is removed)")
                }
            case .smartObject(let so):
                SmartObjectProperties(doc: doc, layerID: layer.id, so: so)
            case .fill(let f) where f.recipe != nil:
                EmptyView()   // shown by RecipeLayerProperties above
            case .fill(let f):
                Caption("Fill")
                PaintStyleEditor(paint: Binding(get: { f.paint }, set: { v in live { l in var n = f; n.paint = v; l.fill = n } }))
                WrappingHStack {
                    Button("Apply") { commit("Edit Fill") }.buttonStyle(PanelButtonStyle())
                    Button("Fill Options…") { FillLayerDialog.open(layer.id) }.buttonStyle(PanelButtonStyle())
                        .help("Solid Color / Gradient Fill / Pattern Fill dialog (also: double-click the layer)")
                }
            case .raster(let r):
                transformInfo(r)
            case .group(let g):
                Text("\(g.children.count) layer\(g.children.count == 1 ? "" : "s")").foregroundStyle(Theme.textDim)
                if let ab = g.artboard { ArtboardProperties(doc: doc, layerID: layer.id, ab: ab) }
            }
            if layer.mask != nil {
                Divider()
                Button("Edit Layer Mask") { doc.editTarget = .mask }.buttonStyle(PanelButtonStyle())
            }
        }
        LayoutProperties(doc: doc, layer: layer)
        Divider()
        Caption("Layer")
        WrappingHStack {
            Button("Layer Style…") { AppModel.shared.dialog = .layerStyle(layer.id) }.buttonStyle(PanelButtonStyle())
            if layer.mask == nil { Button("Add Mask") { AppActions.addMask(.revealAll) }.buttonStyle(PanelButtonStyle()) }
        }
    }

    @ViewBuilder func maskProperties(_ m: LayerMask) -> some View {
        Caption("Layer Mask")
        ValueSlider(label: "Density", value: Binding(get: { m.density * 100 }, set: { v in live { $0.mask?.density = v / 100 } }), range: 0...100, unit: "%", onCommit: { commit("Mask Density") })
        ValueSlider(label: "Feather", value: Binding(get: { m.feather }, set: { v in live { $0.mask?.feather = v } }), range: 0...250, unit: "px", format: "%.1f", onCommit: { commit("Mask Feather") })
        FeatherDirectionPicker(direction: Binding(get: { m.featherDirection ?? .centered }, set: { v in live { $0.mask?.featherDirection = v }; commit("Mask Feather Direction") }), labelWidth: 60)
        WrappingHStack {
            Button("Invert") { AppActions.invertMask() }.buttonStyle(PanelButtonStyle())
            Button(tr(m.isEnabled ? "Disable" : "Enable")) { AppActions.toggleMaskEnabled() }.buttonStyle(PanelButtonStyle())
            Button("Apply") { AppActions.applyMask() }.buttonStyle(PanelButtonStyle())
        }
        WrappingHStack {
            Button("Mask → Selection") {
                doc.setSelection(SelectionOps.fromAlpha(m.buffer, origin: m.origin, width: doc.state.width, height: doc.state.height), commitName: "Load Selection")
            }.buttonStyle(PanelButtonStyle())
            Button("Edit Content") { doc.editTarget = .content }.buttonStyle(PanelButtonStyle())
        }
    }

    @ViewBuilder func transformInfo(_ r: RasterContent) -> some View {
        if let b = r.buffer.opaqueBounds() {
            // X / Y of a layer in an artboard are measured from the artboard's top-left corner (as in Photoshop)
            let o = ArtboardCoords.layerOrigin(layer.id, doc.state)
            let x = Double(b.x + r.origin.x) - Double(o.x), y = Double(b.y + r.origin.y) - Double(o.y)
            Caption("Transform")
            HStack {
                NumberField(label: "X", value: Binding(get: { x }, set: { v in live { $0.translate(dx: v - x, dy: 0) } }), width: 50, onCommit: { commit("Move") })
                NumberField(label: "Y", value: Binding(get: { y }, set: { v in live { $0.translate(dx: 0, dy: v - y) } }), width: 50, onCommit: { commit("Move") })
            }
            Text("W: \(b.width) px   H: \(b.height) px").foregroundStyle(Theme.textDim)
            HStack {
                IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal") { AppActions.flipLayers(horizontal: true) }
                IconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical") { AppActions.flipLayers(horizontal: false) }
                IconButton(symbol: "rotate.right", help: "Rotate 90° CW") { AppActions.rotateLayers(degrees: 90) }
                IconButton(symbol: "rotate.left", help: "Rotate 90° CCW") { AppActions.rotateLayers(degrees: -90) }
                IconButton(symbol: "crop.rotate", help: "Free Transform (⌘T)") { AppActions.freeTransform() }
            }
        } else {
            Text("Empty layer").foregroundStyle(Theme.textFaint)
        }
    }
}

// TextProperties moved to UI/Panels/TypePanels.swift

struct ShapeProperties: View {
    @Binding var s: ShapeContent
    var onCommit: () -> Void
    /// X / Y are measured from here (the top-left corner of the artboard holding the layer; the canvas corner otherwise).
    var origin: CGPoint = .zero
    @State private var strokeOptionsOpen = true
    var body: some View {
        let b = s.path.bounds
        Caption("Shape")
        HStack {
            NumberField(label: "W", value: Binding(get: { Double(b.width) }, set: { v in scale(sx: v / max(1, Double(b.width)), sy: 1) }), width: 50, onCommit: onCommit)
            NumberField(label: "H", value: Binding(get: { Double(b.height) }, set: { v in scale(sx: 1, sy: v / max(1, Double(b.height))) }), width: 50, onCommit: onCommit)
        }
        HStack {
            NumberField(label: "X", value: Binding(get: { Double(b.minX - origin.x) }, set: { v in s.transform = s.transform.concatenating(CGAffineTransform(translationX: CGFloat(v) + origin.x - b.minX, y: 0)) }), width: 50, onCommit: onCommit)
            NumberField(label: "Y", value: Binding(get: { Double(b.minY - origin.y) }, set: { v in s.transform = s.transform.concatenating(CGAffineTransform(translationX: 0, y: CGFloat(v) + origin.y - b.minY)) }), width: 50, onCommit: onCommit)
        }
        WrappingHStack {
            Text("Fill").foregroundStyle(Theme.textDim)
            PaintStylePicker(paint: $s.fill, onCommit: onCommit)
            Spacer()
            Text("Stroke").foregroundStyle(Theme.textDim)
            PaintStylePicker(paint: $s.stroke.paint, onCommit: onCommit)
        }
        ValueSlider(label: "Stroke Width", value: Binding(get: { s.stroke.width }, set: { s.stroke.setWidth($0) }), range: 0...200, unit: "px", format: "%.1f", onCommit: onCommit)
        SectionHeader(title: "Stroke Options", expanded: $strokeOptionsOpen)
        if strokeOptionsOpen {
            StrokeOptionsEditor(stroke: $s.stroke, onCommit: onCommit)
        }
        WrappingHStack(spacing: 6) {
            Text("Path Operations").foregroundStyle(Theme.textDim)
            PathOperationMenu(current: VectorEditing.currentComponentOperation, allowNew: false) { op in if let op { VectorEditing.setComponentOperation(op) } }
            Spacer()
        }
        .help("Combine, subtract, intersect or exclude the shape's components (select one with the Path Selection tool, or all but the first change); Merge Shape Components bakes the result")
        switch s.geometry {
        case .rectangle(let r, let rad):
            ValueSlider(label: "Corner Radius", value: Binding(get: { rad }, set: { s.geometry = .rectangle(r, cornerRadius: $0) }), range: safeRange(0, Double(min(r.width, r.height) / 2)), unit: "px", onCommit: onCommit)
        case .polygon(let r, let sides, let star):
            ValueSlider(label: "Sides", value: Binding(get: { Double(sides) }, set: { s.geometry = .polygon(r, sides: Int($0), starRatio: star) }), range: 3...64, step: 1, onCommit: onCommit)
            ValueSlider(label: "Star Ratio", value: Binding(get: { star * 100 }, set: { s.geometry = .polygon(r, sides: sides, starRatio: $0 / 100) }), range: 5...100, unit: "%", onCommit: onCommit)
        case .line(let a, let bb, let w):
            ValueSlider(label: "Weight", value: Binding(get: { w }, set: { s.geometry = .line(a, bb, weight: $0) }), range: 0.5...200, unit: "px", onCommit: onCommit)
        default: EmptyView()
        }
    }

    func scale(sx: Double, sy: Double) {
        let b = s.path.bounds
        let t = CGAffineTransform(translationX: b.minX, y: b.minY).scaledBy(x: CGFloat(sx), y: CGFloat(sy)).translatedBy(x: -b.minX, y: -b.minY)
        s.transform = s.transform.concatenating(t)
    }
}

struct SmartObjectProperties: View {
    @Bindable var doc: Document
    let layerID: UUID
    let so: SmartObjectContent

    var body: some View {
        Caption("Smart Object")
        HStack {
            Image(systemName: "doc.on.doc").foregroundStyle(Theme.textDim)
            Text(tr(so.sourceName)).lineLimit(1)
            Spacer()
            Text("\(Int(so.source.size.width))×\(Int(so.source.size.height))").foregroundStyle(Theme.textDim)
        }
        WrappingHStack {
            Button("Edit Contents") { AppActions.editSmartContents(layerID) }.buttonStyle(PanelButtonStyle())
            Button("Replace…") { AppActions.replaceSmartContents() }.buttonStyle(PanelButtonStyle())
            if so.linkedURL != nil {
                Button("Relink…") { doc.selectLayer(layerID); AppActions.relinkToFile() }.buttonStyle(PanelButtonStyle())
            }
        }
        // how Replace Contents / Relink / Update Modified Content place a file of another size
        Picker("New contents", selection: Binding(get: { so.contentFit ?? .fit }, set: { v in
            doc.updateLayer(layerID) { $0.smart?.contentFit = v == .fit ? nil : v }
            doc.commit("Smart Object Contents Fit")
        })) {
            ForEach(SmartContentFit.allCases, id: \.self) { Text(tr($0.label)).tag($0) }
        }
        .help("When the contents are replaced or relinked to a file of another size: fit it into the current box (aspect ratio kept, centred, rotation and perspective kept), or keep the object's scale so its size follows the file's pixel size, as Photoshop does")
        let sc = AppActions.smartObjectScale(so)
        WrappingHStack {
            Text(tr(String(format: "Scale %.0f%% × %.0f%%", sc.x * 100, sc.y * 100))).foregroundStyle(abs(sc.x - 1) < 0.005 && abs(sc.y - 1) < 0.005 ? Theme.textDim : Theme.text)
            Spacer()
            Button("100%") { AppActions.resetSmartObject([layerID], keepRotation: true) }.buttonStyle(PanelButtonStyle())
                .help("Reset to the original size, keeping the rotation")
            Button("Reset Transform") { AppActions.resetSmartObject([layerID], keepRotation: false) }.buttonStyle(PanelButtonStyle())
                .help("Original size, no rotation, no warp")
        }
        Divider()
        HStack {
            Caption("Smart Filters")
            Spacer()
            Toggle("", isOn: Binding(get: { so.filtersEnabled }, set: { v in doc.updateLayer(layerID) { $0.smart?.filtersEnabled = v }; doc.commit("Toggle Smart Filters") }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        if so.filters.isEmpty {
            Text("Use the Filter menu to add non-destructive smart filters.").foregroundStyle(Theme.textFaint)
        }
        ForEach(Array(so.filters.enumerated().reversed()), id: \.element.id) { i, f in
            HStack(spacing: 6) {
                Button {
                    doc.updateLayer(layerID) { $0.smart?.filters[i].enabled.toggle() }
                    doc.commit("Toggle Smart Filter")
                } label: { Image(systemName: f.enabled ? "eye" : "eye.slash").foregroundStyle(Theme.textDim) }.buttonStyle(.plain)
                Text(tr(f.kind.displayName))
                Spacer()
                Text(tr(f.blendMode == .normal && f.opacity >= 0.999 ? "" : "\(tr(f.blendMode.displayName)) \(Int(f.opacity * 100))%")).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Button { AppModel.shared.dialog = .filter(f.kind, smartLayer: layerID, editingFilter: f.id) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("Edit")
                Button {
                    doc.updateLayer(layerID) { $0.smart?.filters.remove(at: i) }
                    doc.commit("Delete Smart Filter")
                } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete")
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
        }
    }
}

// MARK: - Adjustments panel

struct AdjustmentsPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add an adjustment").font(Theme.fontBold).foregroundStyle(Theme.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 6)], alignment: .leading, spacing: 6) {   // (as many columns as fit)
                    ForEach(AdjustmentKind.layerKinds) { k in
                        Button { AppActions.newAdjustmentLayer(k) } label: {
                            Image(systemName: k.symbol).font(.system(size: 15)).frame(width: 36, height: 30)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
                        }
                        .buttonStyle(.plain)
                        .help(tr(k.displayName))
                    }
                }
                Divider()
                Text("Fill layers").font(Theme.fontBold).foregroundStyle(Theme.text)
                WrappingHStack {
                    Button("Solid Color") { FillLayerDialog.newLayer(.solid) }.buttonStyle(PanelButtonStyle())
                    Button("Gradient") { FillLayerDialog.newLayer(.gradient) }.buttonStyle(PanelButtonStyle())
                    Button("Pattern") { FillLayerDialog.newLayer(.pattern) }.buttonStyle(PanelButtonStyle())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// CharacterPanel moved to UI/Panels/TypePanels.swift
