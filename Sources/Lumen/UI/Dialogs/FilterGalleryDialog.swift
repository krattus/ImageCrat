import SwiftUI
import CoreImage
import ImageCratCore

/// Thumbnails of each gallery look applied to the active layer (cached per document revision).
enum GalleryThumbs {
    private static var cache: [String: CGImage] = [:]
    private static var sourceKey = ""
    private static var source: CIImage?

    static func thumb(_ f: GalleryFilter, doc: Document) -> CGImage? {
        let key = "\(doc.id)-\(doc.revision)"
        if key != sourceKey {
            cache.removeAll()
            sourceKey = key
            let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
            // crop a square from the center of the active layer, downscaled
            let img = (doc.activeLayer.flatMap { Compositor.shared.contentImage($0, space: space) } ?? Compositor.shared.composite(doc.state)).cropped(to: space.ciCanvas)
            let side = min(space.ciCanvas.width, space.ciCanvas.height) * 0.6
            let r = CGRect(x: space.ciCanvas.midX - side / 2, y: space.ciCanvas.midY - side / 2, width: side, height: side)
            let s = 120 / side
            let small = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY).concatenating(CGAffineTransform(scaleX: s, y: s)))
            if let cg = RenderEngine.cgImage(small.composited(over: CIImage.color(.white, CGRect(x: 0, y: 0, width: 120, height: 120))), rect: CGRect(x: 0, y: 0, width: 120, height: 120)) {
                source = CIImage(cgImage: cg)
            }
        }
        if let c = cache[f.rawValue] { return c }
        guard let src = source else { return nil }
        let e = GalleryEntry(f)
        let out = f.apply(src, values: e.values, fg: AppModel.shared.foreground, bg: AppModel.shared.background, canvas: src.extent)
        let cg = RenderEngine.cgImage(out.composited(over: CIImage.color(.white, src.extent)), rect: src.extent)
        cache[f.rawValue] = cg
        return cg
    }
}

struct FilterGalleryDialog: View {
    let smartLayer: UUID?
    let editingFilter: UUID?
    @State private var inst: FilterInstance
    @State private var selected: UUID?
    @State private var category = "Artistic"

    init(smartLayer: UUID?, editingFilter: UUID?) {
        self.smartLayer = smartLayer
        self.editingFilter = editingFilter
        var i = FilterInstance(kind: .filterGallery, colors: [AppModel.shared.foreground, AppModel.shared.background])
        if let eid = editingFilter, let sl = smartLayer, let ex = AppActions.doc?.state.layer(sl)?.smart?.filters.first(where: { $0.id == eid }) {
            i = ex
        } else {
            i.gallery = [GalleryEntry(.dryBrush)]
            if smartLayer != nil { i = AppActions.withSelectionMask(i, AppActions.doc) }   // the selection becomes the filter mask
        }
        _inst = State(initialValue: i)
        _selected = State(initialValue: i.gallery.last?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Filter Gallery" + (smartLayer != nil ? " (Smart Filter)" : AppActions.filterTargetSuffix(AppActions.doc)))).font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                // Looks
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $category) { ForEach(GalleryFilter.categories, id: \.self) { Text(tr($0)).tag($0) } }.labelsHidden().frame(width: 280)
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 3), spacing: 8) {
                            ForEach(GalleryFilter.allCases.filter { $0.category == category }) { f in
                                VStack(spacing: 2) {
                                    ZStack {
                                        Color.black
                                        if let d = AppActions.doc, let cg = GalleryThumbs.thumb(f, doc: d) { Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                                    }
                                    .frame(width: 84, height: 60).clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(currentFilter == f ? Theme.accent : Color(white: 0.3), lineWidth: currentFilter == f ? 2 : 0.5))
                                    Text(tr(f.displayName)).font(.system(size: 9)).foregroundStyle(Theme.textDim).lineLimit(1)
                                }
                                .onTapGesture { choose(f) }
                            }
                        }
                    }
                    .frame(width: 280, height: 380)
                }
                Divider()
                // Settings + effect stack
                VStack(alignment: .leading, spacing: 8) {
                    if let i = inst.gallery.firstIndex(where: { $0.id == selected }) {
                        Text(tr(inst.gallery[i].filter.displayName)).font(Theme.fontBold)
                        ForEach(inst.gallery[i].filter.params) { p in paramControl(p, entryIndex: i) }
                    } else {
                        Text("Add an effect layer").foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    Caption("Effect Layers")
                    VStack(spacing: 1) {
                        ForEach(inst.gallery.reversed()) { e in
                            HStack {
                                Button { if let i = inst.gallery.firstIndex(where: { $0.id == e.id }) { inst.gallery[i].visible.toggle() } } label: {
                                    Image(systemName: e.visible ? "eye" : "eye.slash").font(.system(size: 10))
                                }.buttonStyle(.plain)
                                Text(tr(e.filter.displayName))
                                Spacer()
                            }
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 3).fill(selected == e.id ? Theme.selection : Theme.fieldBG))
                            .onTapGesture { selected = e.id; category = e.filter.category }
                        }
                    }
                    HStack {
                        Button { let e = GalleryEntry(currentFilter ?? .dryBrush); inst.gallery.append(e); selected = e.id } label: { Image(systemName: "plus") }
                            .buttonStyle(PanelButtonStyle()).help("New effect layer")
                        Button { inst.gallery.removeAll { $0.id == selected }; selected = inst.gallery.last?.id } label: { Image(systemName: "trash") }
                            .buttonStyle(PanelButtonStyle()).help("Delete effect layer").disabled(inst.gallery.count <= 1)
                    }
                    Toggle2(label: "Preview", on: $preview)
                }
                .frame(width: 280)
            }
            HStack {
                Spacer()
                Button("Cancel") { cancel(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { FieldEdits.commit(); ok(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .onChange(of: inst) { _, _ in updatePreview() }
        .onChange(of: preview) { _, _ in updatePreview() }
        .onAppear { if let f = inst.gallery.last?.filter { category = f.category }; updatePreview() }
    }

    @State private var preview = true

    var currentFilter: GalleryFilter? { inst.gallery.first { $0.id == selected }?.filter }

    private func choose(_ f: GalleryFilter) {
        if let i = inst.gallery.firstIndex(where: { $0.id == selected }) {
            let e = GalleryEntry(f)
            inst.gallery[i].filter = f
            inst.gallery[i].values = e.values
        } else {
            let e = GalleryEntry(f); inst.gallery.append(e); selected = e.id
        }
    }

    @ViewBuilder func paramControl(_ p: FilterParam, entryIndex i: Int) -> some View {
        let b = Binding(get: { inst.gallery[i].values[p.key] ?? p.defaultValue }, set: { inst.gallery[i].values[p.key] = $0 })
        switch p.kind {
        case .slider(let r):
            ValueSlider(label: p.label, value: b, range: r, unit: p.unit, format: r.upperBound - r.lowerBound <= 20 ? "%.1f" : "%.0f", labelWidth: 96)
        case .choice(let opts):
            Picker(tr(p.label), selection: Binding(get: { Int(b.wrappedValue) }, set: { b.wrappedValue = Double($0) })) {
                ForEach(Array(opts.enumerated()), id: \.offset) { k, o in Text(tr(o)).tag(k) }
            }
        case .toggle:
            Toggle2(label: p.label, on: Binding(get: { b.wrappedValue > 0.5 }, set: { b.wrappedValue = $0 ? 1 : 0 }))
        case .angle:
            HStack { Text(tr(p.label)).foregroundStyle(Theme.textDim).frame(width: 96, alignment: .leading); AngleDial(angle: b); NumberField(label: "", value: b, width: 44) }
        case .percentPoint:
            ValueSlider(label: p.label, value: Binding(get: { b.wrappedValue * 100 }, set: { b.wrappedValue = $0 / 100 }), range: 0...100, unit: "%", labelWidth: 96)
        }
    }

    private func updatePreview() {
        guard let d = AppActions.doc else { return }
        if let sl = smartLayer {
            var filters = d.committedState.layer(sl)?.smart?.filters ?? []
            if preview { if let eid = editingFilter, let i = filters.firstIndex(where: { $0.id == eid }) { filters[i] = inst } else { filters.append(inst) } }
            d.updateLayer(sl) { $0.smart?.filters = filters }
            return
        }
        if preview {
            let f = inst
            let canvas = CanvasSpace(width: d.state.width, height: d.state.height).ciCanvas
            AppActions.setPreview { f.apply($0, canvas: canvas) }
        } else { AppActions.setPreview(nil) }
    }

    private func ok() {
        guard let d = AppActions.doc else { return }
        if let sl = smartLayer {
            var filters = d.committedState.layer(sl)?.smart?.filters ?? []
            if let eid = editingFilter, let i = filters.firstIndex(where: { $0.id == eid }) { filters[i] = inst } else { filters.append(inst) }
            d.updateLayer(sl) { $0.smart?.filters = filters }
            d.commit("Filter Gallery")
            return
        }
        AppActions.setPreview(nil)
        AppActions.applyFilter(inst)
    }

    private func cancel() {
        guard let d = AppActions.doc else { return }
        if smartLayer != nil { d.revertUncommitted() } else { AppActions.setPreview(nil) }
    }
}
