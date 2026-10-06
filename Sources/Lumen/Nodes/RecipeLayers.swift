import AppKit
import CoreImage
import ImageCratCore

/// Where a recipe graph lives inside a document.
enum RecipeTarget: Equatable, Hashable {
    /// A Recipe layer (fill layer whose `FillContent.recipe` is set).
    case layer(UUID)
    /// A Recipe smart filter on a smart object.
    case smartFilter(layer: UUID, filter: UUID)

    /// Key of the evaluator cache (same ids the compositor hooks use).
    var cacheID: UUID {
        switch self {
        case .layer(let id): return id
        case .smartFilter(_, let f): return f
        }
    }

    var layerID: UUID {
        switch self {
        case .layer(let id): return id
        case .smartFilter(let l, _): return l
        }
    }
}

extension DocumentState {
    func recipeGraph(_ t: RecipeTarget) -> RecipeGraph? {
        switch t {
        case .layer(let id):
            if case .fill(let f)? = layer(id)?.content { return f.recipe }
            return nil
        case .smartFilter(let lid, let fid):
            return layer(lid)?.smart?.filters.first { $0.id == fid }?.recipe
        }
    }

    mutating func setRecipeGraph(_ t: RecipeTarget, _ g: RecipeGraph) {
        switch t {
        case .layer(let id):
            updateLayer(id) { l in
                if case .fill(var f) = l.content { f.recipe = g; l.content = .fill(f) }
            }
        case .smartFilter(let lid, let fid):
            updateLayer(lid) { l in
                guard var so = l.smart, let i = so.filters.firstIndex(where: { $0.id == fid }) else { return }
                so.filters[i].recipe = g
                l.smart = so
            }
        }
    }

    /// Every recipe in the document (layers and smart filters).
    var recipeTargets: [RecipeTarget] {
        var out: [RecipeTarget] = []
        for l in allLayers {
            if case .fill(let f) = l.content, f.recipe != nil { out.append(.layer(l.id)) }
            if let so = l.smart { for f in so.filters where f.kind == .recipe { out.append(.smartFilter(layer: l.id, filter: f.id)) } }
        }
        return out
    }
}

extension Layer {
    var isRecipe: Bool { if case .fill(let f) = content { return f.recipe != nil }; return false }
    var recipe: RecipeGraph? { if case .fill(let f) = content { return f.recipe }; return nil }

    static func recipe(name: String, graph: RecipeGraph) -> Layer {
        Layer(name: name, content: .fill(FillContent(paint: .none, recipe: graph)))
    }
}

/// Commands for Recipe layers and Recipe smart filters.
enum RecipeActions {
    static var doc: Document? { AppModel.shared.activeDocument }

    /// Layer Below → Output (shows the layers underneath unchanged until nodes are added).
    static func passthroughGraph(name: String = "Recipe") -> RecipeGraph {
        var b = RecipeBuilder(name)
        let s = b.add("in.source", col: 0)
        let o = b.add(RecipeLibrary.outputNodeType, col: 2)
        b.wire(s, "Image", o, "Image")
        return b.graph
    }

    /// Edits a recipe in place. Live (uncommitted) unless `commit` is given.
    static func mutate(_ d: Document, _ t: RecipeTarget, commit: String? = nil, _ body: (inout RecipeGraph) -> Void) {
        guard var g = d.state.recipeGraph(t) else { return }
        body(&g)
        d.state.setRecipeGraph(t, g)
        if let n = commit { d.commit(n) }
    }

    // MARK: Create

    @discardableResult
    static func newRecipeLayer(_ graph: RecipeGraph? = nil, in document: Document? = nil, openEditor: Bool = false) -> UUID? {
        guard let d = document ?? doc else { return nil }
        var g = graph ?? passthroughGraph()
        regenerateIDs(&g)
        var l = Layer.recipe(name: d.nextLayerName(g.name == "Recipe" ? "Recipe" : g.name), graph: g)
        if let sel = d.state.selection {
            l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0)
            d.state.selection = nil
        }
        d.addLayer(l, commitName: "New Recipe Layer")
        if openEditor { RecipeEditorWindow.shared.open(document: d, target: .layer(l.id)) }
        return l.id
    }

    /// Adds a Recipe smart filter to a smart object layer.
    @discardableResult
    static func addRecipeFilter(_ graph: RecipeGraph? = nil, in document: Document? = nil, layerID: UUID? = nil, openEditor: Bool = false) -> RecipeTarget? {
        guard let d = document ?? doc, let lid = layerID ?? d.activeLayerID, d.state.layer(lid)?.isSmartObject == true else { return nil }
        var g = graph ?? passthroughGraph(name: "Recipe Filter")
        regenerateIDs(&g)
        var f = FilterInstance(kind: .recipe)
        f.recipe = g
        d.updateLayer(lid) { l in
            guard var so = l.smart else { return }
            so.filters.append(f)
            l.smart = so
        }
        d.commit("Recipe Filter")
        let t = RecipeTarget.smartFilter(layer: lid, filter: f.id)
        if openEditor { RecipeEditorWindow.shared.open(document: d, target: t) }
        return t
    }

    /// Filter ▸ Recipe Filter… on a layer that is not a smart object: offers to convert (or to apply destructively to pixel layers).
    static func applyRecipeFilterInteractive(_ graph: RecipeGraph, openEditor: Bool) {
        guard let d = doc, let l = d.activeLayer else { Beep.play(); return }
        if l.isSmartObject {
            addRecipeFilter(graph, openEditor: openEditor)
            return
        }
        let a = NSAlert()
        a.messageText = tr("Recipe filters are non-destructive smart filters.")
        a.informativeText = tr("Convert “\(l.name)” to a Smart Object to keep the recipe editable" + (l.isRaster ? ", or apply it to the pixels once." : "."))
        a.addButton(withTitle: tr("Convert to Smart Object"))
        if l.isRaster { a.addButton(withTitle: tr("Apply to Pixels")) }
        a.addButton(withTitle: tr("Cancel"))
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            AppActions.convertToSmartObject()
            addRecipeFilter(graph, openEditor: openEditor)
        } else if l.isRaster && r == .alertSecondButtonReturn {
            applyDestructively(graph)
        }
    }

    /// Bakes a recipe into the active pixel layer (the layer's pixels are the recipe's "Layer Below").
    static func applyDestructively(_ graph: RecipeGraph) {
        guard let d = doc else { return }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let st = d.state
        let id = UUID()
        AppActions.applyToActiveLayer(name: graph.name) { img in
            RecipeRuntime.shared.render(target: id, graph: graph, source: img, space: sp, state: st)
        }
        RecipeRuntime.shared.forget([id])   // one-off target: its evaluator would otherwise hold the whole state

    }

    /// New ids for nodes / wires so two copies of a preset never share identifiers.
    static func regenerateIDs(_ g: inout RecipeGraph) {
        var map: [UUID: UUID] = [:]
        for i in g.nodes.indices { let n = UUID(); map[g.nodes[i].id] = n; g.nodes[i].id = n }
        for i in g.connections.indices {
            g.connections[i].id = UUID()
            g.connections[i].from = map[g.connections[i].from] ?? g.connections[i].from
            g.connections[i].to = map[g.connections[i].to] ?? g.connections[i].to
        }
        for i in g.exposed.indices { g.exposed[i].id = UUID(); g.exposed[i].node = map[g.exposed[i].node] ?? g.exposed[i].node }
        for i in g.frames.indices { g.frames[i].id = UUID() }
        if let s = g.solo { g.solo = map[s] }
    }

    // MARK: Rasterize

    /// Replaces a Recipe layer with pixels of exactly what it shows now.
    static func rasterize(_ id: UUID? = nil) {
        guard let d = doc, let lid = id ?? d.activeLayerID, let l = d.state.layer(lid), l.isRecipe else { return }
        let r = Compositor.shared.rasterize(l, state: d.state, includeEffects: false)
        d.updateLayer(lid) { $0.content = .raster(r); $0.fillOpacity = 1 }
        d.commit("Rasterize Recipe")
    }

    // MARK: Editing entry points

    static func target(for layer: Layer) -> RecipeTarget? {
        if layer.isRecipe { return .layer(layer.id) }
        if let f = layer.smart?.filters.last(where: { $0.kind == .recipe }) { return .smartFilter(layer: layer.id, filter: f.id) }
        return nil
    }

    static func openEditor(_ t: RecipeTarget? = nil) {
        guard let d = doc else { return }
        if let t { RecipeEditorWindow.shared.open(document: d, target: t); return }
        guard let l = d.activeLayer, let tt = target(for: l) else { Beep.play(); return }
        RecipeEditorWindow.shared.open(document: d, target: tt)
    }

    // MARK: Exposed parameters

    /// Value access for an exposed parameter (Properties panel, tests).
    static func exposedNumber(_ g: RecipeGraph, _ e: RecipeExposed) -> Double? {
        guard let n = g.node(e.node), let p = RecipeLibrary.spec(n.type)?.param(e.key), p.isNumeric else { return nil }
        return n.numbers[e.key] ?? p.def
    }

    static func setExposedNumber(_ g: inout RecipeGraph, _ e: RecipeExposed, _ v: Double) {
        guard let i = g.index(e.node), let p = RecipeLibrary.spec(g.nodes[i].type)?.param(e.key) else { return }
        g.nodes[i].numbers[e.key] = p.sanitized(v)
    }
}
