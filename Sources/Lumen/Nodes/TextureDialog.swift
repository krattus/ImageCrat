import SwiftUI
import AppKit
import CoreImage
import Observation
import ImageCratCore

/// Where a generated texture goes.
enum TextureOutput: String, CaseIterable, Identifiable {
    case newLayer = "New Layer"
    case recipeLayer = "Recipe Layer (live)"
    case fillSelection = "Fill Selection / Layer"
    case layerMask = "Layer Mask"
    case pattern = "Pattern (library)"
    var id: String { rawValue }
}

/// Commands behind Filter ▸ Render ▸ Textures.
enum TextureActions {
    static var doc: Document? { AppModel.shared.activeDocument }
    static var lastSettings: TextureSettings?

    static func image(_ s: TextureSettings, _ d: Document) -> CIImage {
        TextureEngine.render(s, space: CanvasSpace(width: d.state.width, height: d.state.height))
    }

    /// A Recipe graph with just this generator (the "Recipe node" output).
    static func graph(_ s: TextureSettings) -> RecipeGraph {
        let name = TextureCatalog.gen(s.gen)?.name ?? "Texture"
        var b = RecipeBuilder(name)
        let n = b.add("gen." + s.gen, col: 0) { node in
            for (k, v) in s.values { node.numbers[k] = v }
            for (k, v) in s.colors { node.colors[k] = v }
            if let r = s.ramp { node.gradients["ramp"] = r }
        }
        let o = b.add(RecipeLibrary.outputNodeType, col: 1)
        b.wire(n, "Image", o, "Image")
        b.expose(n, "scale", "Scale"); b.expose(n, "seed", "Seed")
        return b.graph
    }

    @discardableResult
    static func apply(_ s: TextureSettings, output: TextureOutput, patternSize: Int = 512, in document: Document? = nil) -> Bool {
        guard let d = document ?? doc else { return false }
        lastSettings = s
        let name = TextureCatalog.gen(s.gen)?.name ?? "Texture"
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        switch output {
        case .newLayer:
            let buf = RenderEngine.renderBuffer(image(s, d), docRect: d.state.canvasRect, space: sp)
            var l = Layer.raster(name: d.nextLayerName(name), buffer: buf)
            if let sel = d.state.selection { l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0); d.state.selection = nil }
            d.addLayer(l, commitName: "Render \(name)")
        case .recipeLayer:
            RecipeActions.newRecipeLayer(graph(s), in: d)
        case .fillSelection:
            guard let id = d.activeLayerID, let l = d.state.layer(id) else { return false }
            let target: EditTarget = d.editTarget == .mask && l.mask != nil ? .mask : .content
            if target == .content && !l.isRaster { AppActions.offerRasterize(layer: id); return false }
            if l.locks.pixelsLocked { Beep.play(); return false }
            guard let (w, o) = d.beginPixelEdit(layerID: id, target: target) else { return false }
            let orig = sp.place(w, at: o)
            var result = image(s, d).cropped(to: orig.extent)
            if let sel = d.state.selection {
                result = result.mixed(with: orig, mask: sel.ciImage.composited(over: CIImage.color(.black, orig.extent.union(sp.ciCanvas))))
            }
            if l.locks.transparency && target == .content { result = result.masked(byAlphaOf: orig) }
            RenderEngine.render(result, into: w, docOrigin: o, space: sp)
            d.commit("Render \(name)")
        case .layerMask:
            guard let id = d.activeLayerID, d.state.layer(id) != nil else { return false }
            let gray = RenderEngine.renderBuffer(image(s, d).composited(over: CIImage.color(.black, sp.ciCanvas)), docRect: d.state.canvasRect, space: sp, format: .gray)
            d.updateLayer(id) { $0.mask = LayerMask(buffer: gray, origin: .zero, outsideValue: 0) }
            d.commit("\(name) to Layer Mask")
        case .pattern:
            let w = Int(s.value("tileW")) >= 8 ? Int(s.value("tileW")) : patternSize, h = Int(s.value("tileH")) >= 8 ? Int(s.value("tileH")) : patternSize
            let buf = TextureEngine.tileBuffer(s, width: w, height: h)
            let app = AppModel.shared
            let pid = "texture-\(UUID().uuidString.prefix(8))"
            app.customPatterns.append(PatternDef(id: pid, name: "\(name) \(app.customPatterns.count + 1)", image: buf))
            app.bucket.patternID = pid
            app.setStatus("Added “\(name)” to the Patterns library (\(w)×\(h), seamless).")
        }
        return true
    }

    /// New values inside each parameter's range (seed always changes).
    static func randomized(_ s: TextureSettings, all: Bool = true) -> TextureSettings {
        guard let g = TextureCatalog.gen(s.gen) else { return s }
        var r = s
        r.values["seed"] = Double(Int.random(in: 0...9999))
        guard all else { return r }
        for p in g.params {
            switch p.kind {
            case .slider(let rg):
                // stay within the middle 80 % of the range so results remain usable
                let lo = rg.lowerBound + (rg.upperBound - rg.lowerBound) * 0.1, hi = rg.upperBound - (rg.upperBound - rg.lowerBound) * 0.1
                r.values[p.key] = Double.random(in: lo...hi)
            case .int(let rg): r.values[p.key] = Double(Int.random(in: Int(rg.lowerBound)...Int(rg.upperBound)))
            case .toggle: break
            case .choice(let o): r.values[p.key] = Double(Int.random(in: 0..<max(1, o.count)))
            }
        }
        return r
    }
}

@Observable
final class TextureDialogModel {
    static let shared = TextureDialogModel()
    var settings = TextureSettings(gen: "perlin")
    var output: TextureOutput = .newLayer
    var preview = true
    var patternSize = 512
    var search = ""

    func start(_ gen: String?) {
        if let g = gen { settings = TextureSettings(gen: g) }
        else if let last = TextureActions.lastSettings { settings = last }
    }

    func select(_ gen: String) {
        guard gen != settings.gen else { return }
        let old = settings
        settings = TextureSettings(gen: gen)
        // keep the framing when switching generators
        for k in ["rotation", "offsetX", "offsetY", "seed", "tileable", "tileW", "tileH"] { if let v = old.values[k] { settings.values[k] = v } }
    }

    /// Canvas preview through the document's display override.
    func updatePreview() {
        guard let d = AppActions.doc else { return }
        guard preview else { d.displayOverride = nil; d.setNeedsRender(); return }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        var s = settings
        if output == .pattern {
            s.values["tileable"] = 1
            if s.value("tileW") < 8 { s.values["tileW"] = Double(patternSize) }
            if s.value("tileH") < 8 { s.values["tileH"] = Double(patternSize) }
        }
        var img = TextureEngine.render(s, space: sp)
        if output == .fillSelection, let sel = d.state.selection {
            img = img.masked(byGray: sel.ciImage.composited(over: CIImage.color(.black, sp.ciCanvas)))
        }
        if output == .layerMask {
            img = img.composited(over: CIImage.color(.black, sp.ciCanvas)).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        }
        d.displayOverride = { comp in img.composited(over: comp) }
        d.setNeedsRender()
    }

    func endPreview() {
        guard let d = AppActions.doc else { return }
        d.displayOverride = nil
        d.setNeedsRender()
    }
}

/// Filter ▸ Render ▸ Textures ▸ … : generator browser with live preview.
struct TextureDialog: View {
    @Bindable var m = TextureDialogModel.shared

    var body: some View {
        let gen = TextureCatalog.gen(m.settings.gen) ?? TextureCatalog.all[0]
        DialogFrame(title: "Texture Generator — \(gen.name)", width: 600, okTitle: "Render", onOK: {
            m.endPreview()
            TextureActions.apply(m.settings, output: m.output, patternSize: m.patternSize)
        }, onCancel: { m.endPreview() }, extraButtons: AnyView(HStack {
            Button("Randomize") { m.settings = TextureActions.randomized(m.settings) }.buttonStyle(PanelButtonStyle()).help("New seed and random parameter values")
            Button("Reset") { m.settings = TextureSettings(gen: m.settings.gen) }.buttonStyle(PanelButtonStyle())
        })) {
            HStack(alignment: .top, spacing: 12) {
                browser.frame(width: 170)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        TexturePreview(settings: m.settings, size: CGSize(width: 168, height: 126))
                        VStack(alignment: .leading, spacing: 5) {
                            Picker("Output", selection: $m.output) { ForEach(TextureOutput.allCases) { Text($0.rawValue).tag($0) } }
                            if m.output == .pattern {
                                Picker("Tile", selection: $m.patternSize) { ForEach([128, 256, 512, 1024], id: \.self) { Text("\($0) px").tag($0) } }
                                Text("Patterns are always rendered seamless.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                            } else if m.output == .recipeLayer {
                                Text("Creates a live Recipe layer with this generator as a node (editable, resolution independent).")
                                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                            }
                            Toggle2(label: "Preview on canvas", on: $m.preview)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            TextureParamList(gen: gen, settings: $m.settings)
                        }.padding(.trailing, 8)
                    }
                    .frame(height: 300)
                }
            }
        }
        .onChange(of: m.settings) { _, _ in m.updatePreview() }
        .onChange(of: m.output) { _, _ in m.updatePreview() }
        .onChange(of: m.preview) { _, _ in m.updatePreview() }
        .onChange(of: m.patternSize) { _, _ in m.updatePreview() }
        .onAppear { m.updatePreview(); TextureEngine.prewarm() }
    }

    var browser: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search", text: $m.search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(TextureCategory.allCases, id: \.self) { cat in
                        let list = TextureCatalog.byCategory(cat).filter { g in
                            m.search.isEmpty || g.name.localizedCaseInsensitiveContains(m.search) || g.keywords.contains { $0.localizedCaseInsensitiveContains(m.search) }
                        }
                        if !list.isEmpty {
                            Caption(cat.rawValue).padding(.top, 6).padding(.bottom, 2)
                            ForEach(list, id: \.id) { g in
                                Text(g.name).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6).frame(height: 20)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(g.id == m.settings.gen ? Theme.selection : .clear))
                                    .contentShape(Rectangle())
                                    .onTapGesture { m.select(g.id) }
                            }
                        }
                    }
                }
            }
            .frame(height: 412)
        }
    }
}

/// Sliders for a generator's own and common parameters.
struct TextureParamList: View {
    let gen: TextureGen
    @Binding var settings: TextureSettings

    var body: some View {
        let common = TextureCatalog.commonParams(gen)
        ForEach(["scale", "rotation", "seed"], id: \.self) { k in if let p = common.first(where: { $0.key == k }) { row(p) } }
        if !gen.params.isEmpty { Divider() }
        ForEach(gen.params, id: \.key) { p in row(p) }
        ForEach(gen.colors, id: \.key) { c in
            HStack {
                Text(c.label).foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading)
                ColorWell(color: Binding(get: { settings.colors[c.key] ?? c.def }, set: { settings.colors[c.key] = $0 }), size: 18)
                Spacer()
            }
        }
        Divider()
        if !gen.direct || settings.value("mapRamp") > 0.5 {
            HStack {
                Text("Color Ramp").foregroundStyle(Theme.textDim)
                Spacer()
                Menu("Presets") {
                    Button("Default") { settings.ramp = gen.ramp }
                    Button("Black, White") { settings.ramp = .twoColor(.black, .white, name: "Black, White") }
                    ForEach(AppModel.shared.gradients) { g in Button(g.name) { settings.ramp = g } }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            GradientStopsEditor(gradient: Binding(get: { settings.ramp ?? gen.ramp }, set: { settings.ramp = $0 })).padding(.horizontal, 7)
        }
        ForEach(["contrast", "brightness", "invert", "mapRamp", "offsetX", "offsetY", "tileable", "tileW", "tileH"], id: \.self) { k in
            if let p = common.first(where: { $0.key == k }) {
                if k == "tileW" || k == "tileH" { if settings.value("tileable") > 0.5 { row(p) } } else { row(p) }
            }
        }
        if settings.value("tileable") > 0.5 {
            Text(gen.nativeTile(settings.values) ? "Repeats seamlessly (tile size 0 = canvas). Rotation snaps to 90° steps." : "This generator is made seamless by cross-blending its edges.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }

    @ViewBuilder func row(_ p: TexParam) -> some View {
        let b = Binding(get: { settings.values[p.key] ?? p.def }, set: { settings.values[p.key] = $0 })
        switch p.kind {
        case .slider(let r):
            let span = r.upperBound - r.lowerBound
            ValueSlider(label: p.label, value: b, range: r, unit: p.key == "scale" ? "px" : "", format: span <= 2.5 ? "%.2f" : (span <= 40 ? "%.1f" : "%.0f"), labelWidth: 110)
        case .int(let r):
            if p.key == "seed" {
                HStack(spacing: 4) {
                    ValueSlider(label: p.label, value: b, range: r, step: 1, labelWidth: 110)
                    Button { settings.values["seed"] = Double(Int.random(in: 0...9999)) } label: { Image(systemName: "dice") }.buttonStyle(.plain).help("Random seed")
                }
            } else {
                ValueSlider(label: p.label, value: b, range: r, step: 1, labelWidth: 110)
            }
        case .toggle:
            Toggle2(label: p.label, on: Binding(get: { b.wrappedValue > 0.5 }, set: { b.wrappedValue = $0 ? 1 : 0 }))
        case .choice(let opts):
            HStack {
                Text(p.label).foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(get: { Int(b.wrappedValue) }, set: { b.wrappedValue = Double($0) })) {
                    ForEach(Array(opts.enumerated()), id: \.offset) { i, o in Text(o).tag(i) }
                }.labelsHidden()
            }
        }
    }
}

/// Small rendered preview of a texture (independent of the document).
struct TexturePreview: View {
    let settings: TextureSettings
    let size: CGSize

    var body: some View {
        ZStack {
            CheckerBackground(size: 5)
            if let cg = render() { Image(decorative: cg, scale: 2).resizable() }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.3), lineWidth: 0.5))
    }

    func render() -> CGImage? {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        let img = TextureEngine.render(settings, space: CanvasSpace(width: w, height: h))
        return RenderEngine.readbackContext.createCGImage(img, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGBSpace)
    }
}

// MARK: - Single-node filters (texture utilities)

/// Applies one Recipe node to the active layer as a filter, with live preview: used for the texture utilities
/// (Normal Map from Height, Ambient Occlusion, Make Seamless Tile, Gradient Map).
@Observable
final class RecipeNodeFilterModel {
    static let shared = RecipeNodeFilterModel()
    var node = RecipeNode(type: "util.normal")
    var preview = true
    @ObservationIgnored private let previewID = UUID()

    func start(_ type: String) { node = RecipeLibrary.makeNode(type) }

    /// Layer Below → node → Output.
    var graph: RecipeGraph {
        let spec = RecipeLibrary.spec(node.type)
        var g = RecipeGraph(name: spec?.name ?? "Filter")
        let src = RecipeLibrary.makeNode("in.source", at: CGPoint(x: 40, y: 40))
        var n = node
        n.position = CGPoint(x: 290, y: 40)
        var out = RecipeLibrary.makeNode(RecipeLibrary.outputNodeType, at: CGPoint(x: 540, y: 40))
        out.position = CGPoint(x: 540, y: 40)
        g.nodes = [src, n, out]
        if let i = spec?.inputs.first { _ = try? g.connect(from: src.id, "Image", to: n.id, i.name) }
        if let o = spec?.outputs.first { _ = try? g.connect(from: n.id, o.name, to: out.id, "Image") }
        for p in RecipeLibrary.bodyParams(spec ?? RecipeLibrary.spec("in.source")!) { g.exposed.append(RecipeExposed(node: n.id, key: p.key, label: p.label)) }
        return g
    }

    func updatePreview() {
        guard let d = AppActions.doc else { return }
        if d.activeLayer?.isSmartObject == true || !preview { AppActions.setPreview(nil); return }
        let g = graph
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let id = previewID
        AppActions.setPreview { img in RecipeRuntime.shared.render(target: id, graph: g, source: img, space: sp) }
    }

    func apply() {
        AppActions.setPreview(nil)
        guard let d = AppActions.doc, let l = d.activeLayer else { return }
        if l.isSmartObject { RecipeActions.addRecipeFilter(graph) } else { RecipeActions.applyDestructively(graph) }
    }
}

struct RecipeNodeFilterDialog: View {
    @Bindable var m = RecipeNodeFilterModel.shared

    var body: some View {
        let spec = RecipeLibrary.spec(m.node.type)
        DialogFrame(title: (spec?.name ?? "Filter") + (AppActions.doc?.activeLayer?.isSmartObject == true ? " (Recipe Smart Filter)" : ""), width: 360,
                    onOK: { m.apply() }, onCancel: { AppActions.setPreview(nil) }) {
            ForEach(spec?.params ?? [], id: \.key) { p in
                RecipeParamControl(spec: p, node: m.node, edit: { body in body(&m.node) }, commit: {})
            }
            Toggle2(label: "Preview", on: $m.preview)
        }
        .onChange(of: m.node) { _, _ in m.updatePreview() }
        .onChange(of: m.preview) { _, _ in m.updatePreview() }
        .onAppear { m.updatePreview() }
    }
}
