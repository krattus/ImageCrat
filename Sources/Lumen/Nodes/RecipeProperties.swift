import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Exposed parameters ("custom filter UI")

/// The controls a recipe exposes, used by the Properties panel and the Recipe Filter dialog.
struct RecipeExposedControls: View {
    @Bindable var doc: Document
    let target: RecipeTarget

    var body: some View {
        if let g = doc.state.recipeGraph(target) {
            if g.exposed.isEmpty {
                Text("No exposed parameters. Open the Recipe Editor and pin the parameters you want to see here.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(g.exposed) { e in
                if let n = g.node(e.node), let p = RecipeLibrary.spec(n.type)?.param(e.key) {
                    if p.portType != nil, let c = g.input(n.id, p.portName), let src = g.node(c.from) {
                        HStack {
                            Text(e.label).foregroundStyle(Theme.textDim)
                            Spacer()
                            Text("driven by \(src.title ?? RecipeLibrary.spec(src.type)?.name ?? "a node")").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                        }
                    } else {
                        RecipeParamControl(spec: p, label: e.label, node: n, layers: doc.state.allLayers,
                                           edit: { body in RecipeActions.mutate(doc, target) { $0.update(n.id, body) } },
                                           commit: { doc.commit("Recipe: " + e.label) })
                    }
                }
            }
        }
    }
}

/// Section shown in the Properties panel for Recipe layers and smart objects with Recipe filters.
struct RecipeLayerProperties: View {
    @Bindable var doc: Document
    let layerID: UUID

    var targets: [RecipeTarget] {
        guard let l = doc.state.layer(layerID) else { return [] }
        if l.isRecipe { return [.layer(layerID)] }
        return (l.smart?.filters ?? []).filter { $0.kind == .recipe }.map { .smartFilter(layer: layerID, filter: $0.id) }
    }

    var body: some View {
        ForEach(targets, id: \.self) { t in
            if let g = doc.state.recipeGraph(t) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.textDim)
                        Text(g.name).font(Theme.fontBold).lineLimit(1)
                        Spacer()
                        Text(t == .layer(layerID) ? "Recipe Layer" : "Recipe Filter").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    }
                    RecipeExposedControls(doc: doc, target: t)
                    let errs = RecipeRuntime.shared.errors(target: t.cacheID)
                    if !errs.isEmpty {
                        Label("\(errs.count) node\(errs.count == 1 ? "" : "s") need attention (open the editor)", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.fontSmall).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Edit Recipe…") { RecipePresetStore.shared.loadIfNeeded(); RecipeEditorWindow.shared.open(document: doc, target: t) }.buttonStyle(PanelButtonStyle(prominent: true))
                        Menu("Presets") {
                            Section("Built-in") { ForEach(RecipePresets.builtIn) { p in Button(p.name) { load(p, t) } } }
                            let user = RecipePresetStore.shared.user
                            if !user.isEmpty { Section("My Recipes") { ForEach(user) { p in Button(p.name) { load(p, t) } } } }
                            Divider()
                            Button("Save as Preset") {
                                _ = try? RecipePresetStore.shared.save(name: g.name, graph: g)
                                AppModel.shared.setStatus("Saved recipe “\(g.name)”.")
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                        if case .layer = t { Button("Rasterize") { RecipeActions.rasterize(layerID) }.buttonStyle(PanelButtonStyle()) }
                    }
                    Text("\(g.nodes.count) nodes" + (g.solo != nil ? " · viewing a single node" : "")).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
                Divider()
            }
        }
    }

    func load(_ p: RecipePreset, _ t: RecipeTarget) {
        var g = p.graph
        RecipeActions.regenerateIDs(&g)
        RecipeActions.mutate(doc, t, commit: "Recipe: Load “\(p.name)”") { old in g.origin = old.origin; old = g }
    }
}

// MARK: - Preset thumbnails

/// Small previews of recipes rendered over a synthetic sample scene. Built one per run-loop turn (pixels in the
/// background) so opening the preset browser never blocks on shader compilation.
@Observable
final class RecipeThumbnails {
    static let shared = RecipeThumbnails()
    private(set) var images: [String: CGImage] = [:]
    @ObservationIgnored private var pending: [RecipePreset] = []
    @ObservationIgnored private var working = false
    private static let queue = DispatchQueue(label: "app.lumen.recipe.thumbnails", qos: .utility)

    /// Sample "photo": sky gradient, sun, hills, a few shapes.
    static let sample: CIImage = { sampleImage(width: 480, height: 320) }()

    static func sampleImage(width: Int, height: Int) -> CIImage {
        let b = PixelBuffer(width: width, height: height)
        let c = b.context
        let W = CGFloat(width), H = CGFloat(height)
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "2B5FA8")!.cgColor, RGBA(hex: "F2B680")!.cgColor] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: H * 0.72), options: [.drawsAfterEndLocation])
        c.setFillColor(RGBA(hex: "FFF3C4")!.cgColor); c.fillEllipse(in: CGRect(x: W * 0.64, y: H * 0.18, width: W * 0.15, height: W * 0.15))
        c.setFillColor(RGBA(hex: "3F6B4A")!.cgColor)
        c.move(to: CGPoint(x: 0, y: H * 0.68))
        c.addCurve(to: CGPoint(x: W, y: H * 0.6), control1: CGPoint(x: W * 0.3, y: H * 0.45), control2: CGPoint(x: W * 0.6, y: H * 0.82))
        c.addLine(to: CGPoint(x: W, y: H)); c.addLine(to: CGPoint(x: 0, y: H)); c.fillPath()
        c.setFillColor(RGBA(hex: "25422E")!.cgColor)
        c.move(to: CGPoint(x: 0, y: H * 0.86))
        c.addCurve(to: CGPoint(x: W, y: H * 0.8), control1: CGPoint(x: W * 0.35, y: H * 0.7), control2: CGPoint(x: W * 0.7, y: H * 0.95))
        c.addLine(to: CGPoint(x: W, y: H)); c.addLine(to: CGPoint(x: 0, y: H)); c.fillPath()
        c.setFillColor(RGBA(hex: "D8432F")!.cgColor); c.fill(CGRect(x: W * 0.16, y: H * 0.5, width: W * 0.13, height: H * 0.2))
        c.setFillColor(RGBA(hex: "F4EFE4")!.cgColor)
        c.move(to: CGPoint(x: W * 0.14, y: H * 0.5)); c.addLine(to: CGPoint(x: W * 0.225, y: H * 0.38)); c.addLine(to: CGPoint(x: W * 0.31, y: H * 0.5)); c.fillPath()
        c.setFillColor(RGBA(hex: "1B1F3A")!.cgColor); c.fill(CGRect(x: W * 0.205, y: H * 0.6, width: W * 0.04, height: H * 0.1))
        b.markDirty()
        return b.ciImage
    }

    /// Core Image graph of a preset over the sample scene (main thread), scaled to the thumbnail size.
    private func graphImage(_ p: RecipePreset) -> CIImage {
        let sp = CanvasSpace(width: 480, height: 320)
        let ctx = RecipeContext(space: sp)
        ctx.source = RecipeThumbnails.sample
        ctx.sourceToken = 1
        let img = RecipeEvaluator().evaluate(p.graph, ctx: ctx)
        return img.composited(over: CIImage.color(RGBA(gray: 0.2), sp.ciCanvas)).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5), highQualityDownsample: true)
    }

    private static func pixels(_ img: CIImage) -> CGImage? {
        RenderEngine.readbackContext.createCGImage(img, from: CGRect(x: 0, y: 0, width: 240, height: 160), format: .RGBA8, colorSpace: sRGBSpace)
    }

    /// Cached thumbnail, or nil while it is being made (observers refresh when it arrives).
    func image(_ p: RecipePreset) -> CGImage? {
        if let c = images[p.id] { return c }
        if RecipePresetStore.isSelfTest {       // headless snapshots want it right away
            guard let cg = RecipeThumbnails.pixels(graphImage(p)) else { return nil }
            DispatchQueue.main.async { self.images[p.id] = cg }
            return cg
        }
        if !pending.contains(where: { $0.id == p.id }) { pending.append(p) }
        if !working { working = true; DispatchQueue.main.async { self.next() } }
        return nil
    }

    private func next() {
        guard !pending.isEmpty else { working = false; return }
        let p = pending.removeFirst()
        let img = graphImage(p)
        RecipeThumbnails.queue.async {
            let cg = RecipeThumbnails.pixels(img)
            DispatchQueue.main.async {
                if let cg { self.images[p.id] = cg }
                self.next()
            }
        }
    }

    func invalidate(_ id: String) { images.removeValue(forKey: id) }
}

struct RecipePresetCell: View {
    let preset: RecipePreset
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Color(white: 0.2)
                if let cg = RecipeThumbnails.shared.image(preset) { Image(decorative: cg, scale: 2).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(width: 120, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accent : Color(white: 0.3), lineWidth: selected ? 2 : 0.5))
            Text(preset.name).font(Theme.fontSmall).lineLimit(1).frame(width: 120, alignment: .leading)
        }
        .help(preset.blurb)
    }
}

// MARK: - "Recipe Layer…" / "Recipe Filter…" dialogs

struct RecipePresetDialog: View {
    let asFilter: Bool
    @State private var selected: String? = nil      // nil = blank
    @State private var openEditor = true
    @Bindable var store = RecipePresetStore.shared

    var body: some View {
        let presets = store.all.filter { !asFilter || $0.usesSource }
        DialogFrame(title: asFilter ? "Recipe Filter" : "New Recipe Layer", width: 560, okTitle: asFilter ? "Apply" : "Create", onOK: create) {
            Text(asFilter ? "A recipe is a node graph applied non-destructively as a smart filter. Pick a starting point:"
                 : "A Recipe layer's pixels are computed by a node graph — from the layers below, from procedural textures, or both. Pick a starting point:")
                .font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 10), count: 4), alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack {
                            Color(white: 0.2)
                            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26)).foregroundStyle(Theme.textDim)
                        }
                        .frame(width: 120, height: 80).clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected == nil ? Theme.accent : Color(white: 0.3), lineWidth: selected == nil ? 2 : 0.5))
                        Text("Blank Recipe").font(Theme.fontSmall)
                    }
                    .onTapGesture { selected = nil }
                    ForEach(presets) { p in
                        RecipePresetCell(preset: p, selected: selected == p.id).onTapGesture { selected = p.id }
                    }
                }.padding(2)
            }
            .frame(height: 300)
            if let id = selected, let p = presets.first(where: { $0.id == id }) {
                Text(p.blurb.isEmpty ? p.name : p.blurb).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            } else {
                Text("Starts with Layer Below → Output; build the rest in the editor.").font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            }
            Toggle2(label: "Open the Recipe Editor", on: $openEditor)
        }
    }

    func create() {
        let g = selected.flatMap { id in store.all.first { $0.id == id }?.graph }
        if asFilter {
            RecipeActions.applyRecipeFilterInteractive(g ?? RecipeActions.passthroughGraph(name: "Recipe Filter"), openEditor: openEditor)
        } else {
            RecipeActions.newRecipeLayer(g, openEditor: openEditor)
        }
    }
}

/// Editing an existing Recipe smart filter from the Smart Filters list: exposed sliders + blending, like any filter dialog.
struct RecipeFilterDialog: View {
    let smartLayer: UUID?
    let editingFilter: UUID?

    var body: some View {
        if let d = AppActions.doc, let lid = smartLayer, let fid = editingFilter, let f = d.state.layer(lid)?.smart?.filters.first(where: { $0.id == fid }) {
            let t = RecipeTarget.smartFilter(layer: lid, filter: fid)
            DialogFrame(title: "Recipe Filter — \(f.recipe?.name ?? "Recipe")", width: 360, onOK: { d.commit("Recipe Filter") }, onCancel: { d.revertUncommitted() }) {
                RecipeExposedControls(doc: d, target: t)
                Divider()
                HStack {
                    Text("Mode").foregroundStyle(Theme.textDim)
                    BlendModePicker(mode: Binding(get: { f.blendMode }, set: { v in update(d, lid, fid) { $0.blendMode = v } }), width: 120)
                }
                ValueSlider(label: "Opacity", value: Binding(get: { f.opacity * 100 }, set: { v in update(d, lid, fid) { $0.opacity = v / 100 } }), range: 0...100, unit: "%")
                Button("Open Recipe Editor…") {
                    AppModel.shared.dialog = nil
                    RecipeEditorWindow.shared.open(document: d, target: t)
                }.buttonStyle(PanelButtonStyle())
            }
        } else {
            DialogFrame(title: "Recipe Filter", width: 320, onOK: {}) { Text("The filter no longer exists.").foregroundStyle(Theme.textDim) }
        }
    }

    func update(_ d: Document, _ lid: UUID, _ fid: UUID, _ body: (inout FilterInstance) -> Void) {
        d.updateLayer(lid) { l in
            guard var so = l.smart, let i = so.filters.firstIndex(where: { $0.id == fid }) else { return }
            body(&so.filters[i])
            l.smart = so
        }
    }
}

// MARK: - Recipes panel

struct RecipesPanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var store = RecipePresetStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("New Recipe Layer…") { DialogRegistry.show("recipeNewLayer") }.buttonStyle(PanelButtonStyle()).disabled(app.activeDocument == nil)
                    Button("Edit") { RecipeActions.openEditor() }.buttonStyle(PanelButtonStyle())
                        .disabled(app.activeDocument?.activeLayer.flatMap { RecipeActions.target(for: $0) } == nil)
                }
                section("Built-in", RecipePresets.builtIn)
                if !store.user.isEmpty { section("My Recipes", store.user) }
                HStack {
                    Button("Import…") { importRecipe() }.buttonStyle(PanelButtonStyle())
                    if let dir = store.directory { Button("Show Folder") { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); NSWorkspace.shared.open(dir) }.buttonStyle(PanelButtonStyle()) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font).foregroundStyle(Theme.text)
        .onAppear { store.loadIfNeeded() }
    }

    @ViewBuilder func section(_ title: String, _ list: [RecipePreset]) -> some View {
        Caption(title)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(list) { p in
                RecipePresetCell(preset: p)
                    .onTapGesture(count: 2) { RecipeActions.newRecipeLayer(p.graph) }
                    .contextMenu {
                        Button("New Recipe Layer") { RecipeActions.newRecipeLayer(p.graph) }
                        Button("New Recipe Layer and Edit…") { RecipeActions.newRecipeLayer(p.graph, openEditor: true) }
                        if p.usesSource { Button("Apply as Recipe Filter") { RecipeActions.applyRecipeFilterInteractive(p.graph, openEditor: false) } }
                        if !p.builtIn { Divider(); Button("Delete Preset") { store.delete(p) } }
                    }
            }
        }
        Text("Double-click to add as a Recipe layer; right-click for more.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
    }

    func importRecipe() {
        let p = NSOpenPanel()
        p.allowedContentTypes = RecipePresetStore.readableExtensions.sorted().compactMap { UTType(filenameExtension: $0) } + [.json]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            do { try store.importFile(u) } catch { AppActions.alert("Could not import “\(u.lastPathComponent)”.", error.localizedDescription) }
        }
    }
}
