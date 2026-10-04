import Foundation
import CoreImage
import ImageCratCore

/// What the compositor is doing on this thread. Pushed by `Compositor.composite(_ state:)` (a full document render)
/// and by `layerAppearance` / `rasterize` (one layer on its own), so recipes can resolve layer references and,
/// for isolated renders, recover the backdrop the layer really sits on.
enum RecipeAmbient {
    enum Frame {
        case full(DocumentState)
        case isolated(DocumentState)
        var state: DocumentState {
            switch self { case .full(let s), .isolated(let s): return s }
        }
    }

    private final class Box { var stack: [Frame] = []; var rendering = Set<UUID>() }
    private static let key = "app.lumen.recipe.ambient"
    private static var box: Box {
        let d = Thread.current.threadDictionary
        if let b = d[key] as? Box { return b }
        let b = Box()
        d[key] = b
        return b
    }

    static func push(_ f: Frame) { box.stack.append(f) }
    static func pop() { if !box.stack.isEmpty { box.stack.removeLast() } }
    static var current: Frame? { box.stack.last }
    static var state: DocumentState? { box.stack.last?.state }

    /// Recipe layers being evaluated right now (breaks reference loops between layers).
    static var renderingLayers: Set<UUID> {
        get { box.rendering }
        set { box.rendering = newValue }
    }
}

/// Animation clock for the Time node.
enum RecipeClock {
    /// Seconds. Set by `VideoTimelineEngine.apply(at:)` whenever the Video Timeline evaluates a time (playback, scrubbing, export).
    static var time: Double = 0
    private static var overrides: [Double] = []

    /// Runs `body` with an explicit time (tests, custom exporters).
    static func withTime<T>(_ t: Double, _ body: () -> T) -> T {
        overrides.append(t)
        defer { overrides.removeLast() }
        return body()
    }

    static func current(_ state: DocumentState?) -> Double {
        if let o = overrides.last { return o }
        if let st = state {
            if st.videoTimeline != nil { return time }
            if !st.frames.isEmpty, let d = AppModel.shared.activeDocument, let i = TimelineController.shared.selectedIndex(d), i < st.frames.count {
                // frame animation: time at the start of the selected frame
                return st.frames.prefix(i).reduce(0) { $0 + $1.delay }
            }
        }
        return time
    }
}

/// Owns the per-target evaluators (one per Recipe layer / smart filter) and implements the compositor hooks.
final class RecipeRuntime {
    static let shared = RecipeRuntime()

    private let lock = NSRecursiveLock()
    private var evaluators: [UUID: RecipeEvaluator] = [:]
    private var order: [UUID] = []
    private var lastSource: [UUID: (image: CIImage, token: Int)] = [:]
    private var contexts: [UUID: RecipeContext] = [:]
    private var tokenCounter = 0
    private var serial = 0
    /// Content image of each Recipe layer from the latest full-document composite (true backdrop baked into the CI graph).
    private var captured: [UUID: (graph: RecipeGraph, size: CGSize, image: CIImage)] = [:]
    private var capturing = Set<UUID>()
    /// Total graph evaluations (tests).
    private(set) var evaluationCount = 0

    func evaluator(_ id: UUID) -> RecipeEvaluator {
        lock.lock(); defer { lock.unlock() }
        if let e = evaluators[id] {
            if order.last != id { order.removeAll { $0 == id }; order.append(id) }
            return e
        }
        let e = RecipeEvaluator()
        evaluators[id] = e
        order.append(id)
        if order.count > 48 {
            let old = order.removeFirst()
            evaluators.removeValue(forKey: old); lastSource.removeValue(forKey: old); contexts.removeValue(forKey: old); captured.removeValue(forKey: old)
        }
        return e
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        evaluators.removeAll(); order.removeAll(); lastSource.removeAll(); contexts.removeAll(); captured.removeAll()
    }

    /// Drops targets (Recipe layers / smart filters / previews) that no open document has. Each keeps its node outputs
    /// and a context holding a whole DocumentState, so closed documents' pixels would stay alive until 48 others push them out.
    func prune(keeping ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        forget(Set(evaluators.keys).union(captured.keys).subtracting(ids))
    }

    var targetIDs: Set<UUID> { lock.lock(); defer { lock.unlock() }; return Set(evaluators.keys).union(captured.keys) }

    func forget(_ ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        guard !ids.isEmpty else { return }
        for id in ids { evaluators.removeValue(forKey: id); lastSource.removeValue(forKey: id); contexts.removeValue(forKey: id); captured.removeValue(forKey: id) }
        order.removeAll { ids.contains($0) }
    }

    private func makeContext(target: UUID, graph: RecipeGraph, source: CIImage?, space: CanvasSpace, state: DocumentState?, layerID: UUID?) -> RecipeContext {
        let ctx = RecipeContext(space: space)
        ctx.source = source
        if let s = source {
            if let last = lastSource[target], last.image === s { ctx.sourceToken = last.token }
            else { tokenCounter += 1; lastSource[target] = (s, tokenCounter); ctx.sourceToken = tokenCounter }
        } else {
            lastSource.removeValue(forKey: target)
        }
        serial += 1
        ctx.serial = serial
        ctx.state = state
        ctx.layerID = layerID
        ctx.time = RecipeClock.current(state)
        ctx.origin = graph.origin
        contexts[target] = ctx
        return ctx
    }

    /// Evaluates a graph. `source` is what the "Layer Below" node outputs.
    func render(target: UUID, graph: RecipeGraph, source: CIImage?, space: CanvasSpace, state: DocumentState? = nil, layerID: UUID? = nil) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        let ev = evaluator(target)
        let ctx = makeContext(target: target, graph: graph, source: source, space: space, state: state, layerID: layerID)
        evaluationCount += 1
        return ev.evaluate(graph, ctx: ctx)
    }

    /// Outputs of every node for previews, using the context of the latest render of this target.
    func allValues(target: UUID, graph: RecipeGraph, fallbackSpace: CanvasSpace) -> [UUID: [RecipeValue]] {
        lock.lock(); defer { lock.unlock() }
        let ev = evaluator(target)
        let ctx: RecipeContext
        if let c = contexts[target], c.space.width == fallbackSpace.width, c.space.height == fallbackSpace.height {
            c.origin = graph.origin
            ctx = c
        } else {
            ctx = makeContext(target: target, graph: graph, source: nil, space: fallbackSpace, state: nil, layerID: nil)
        }
        return ev.evaluateAll(graph, ctx: ctx)
    }

    func errors(target: UUID) -> [UUID: String] {
        lock.lock(); defer { lock.unlock() }
        return evaluators[target]?.errors ?? [:]
    }

    func graphError(target: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return evaluators[target]?.graphError
    }

    // MARK: Compositor hooks

    /// Pixels of a Recipe layer. `backdrop` is the composite below it (nil when the caller has no backdrop, e.g. thumbnails).
    func layerContent(_ layer: Layer, graph: RecipeGraph, backdrop: CIImage?, space: CanvasSpace) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        let clear = CIImage.clearImage.cropped(to: space.ciCanvas)
        // A layer reference that leads back to this layer: stop here.
        if RecipeAmbient.renderingLayers.contains(layer.id) { return clear }
        RecipeAmbient.renderingLayers.insert(layer.id)
        defer { RecipeAmbient.renderingLayers.remove(layer.id) }

        let amb = RecipeAmbient.current
        let size = CGSize(width: space.width, height: space.height)
        if case .isolated(let st)? = amb, !capturing.contains(layer.id), st.layers.find(layer.id) != nil {
            // Rasterize / PSD export / "layer appearance": bake what the layer shows in the real document.
            if let img = capture(layer.id, in: st) { return img }
        }
        if backdrop == nil, amb == nil, let c = captured[layer.id], c.size == size, c.graph.rendersSame(as: graph) {
            return c.image
        }
        let img = render(target: layer.id, graph: graph, source: backdrop, space: space, state: amb?.state, layerID: layer.id)
        if case .full? = amb { captured[layer.id] = (graph, size, img) }
        return img
    }

    /// Composites the whole document once so the hook records this layer's content with its true backdrop.
    private func capture(_ id: UUID, in st: DocumentState) -> CIImage? {
        capturing.insert(id)
        let saved = RecipeAmbient.renderingLayers
        RecipeAmbient.renderingLayers = []
        defer { capturing.remove(id); RecipeAmbient.renderingLayers = saved }
        captured.removeValue(forKey: id)
        _ = Compositor.shared.composite(st)
        return captured[id]?.image
    }

    /// Recipe smart filter: `img` is the smart object's content (the graph's "Layer Below").
    func smartFilter(_ f: FilterInstance, _ img: CIImage, canvas: CGRect) -> CIImage {
        guard let g = f.recipe else { return img }
        let space = CanvasSpace(width: max(1, Int(canvas.width.rounded())), height: max(1, Int(canvas.height.rounded())))
        return render(target: f.id, graph: g, source: img, space: space, state: RecipeAmbient.state, layerID: nil)
    }

    /// Appearance (or raw content) of another layer for the "Layer" input node.
    static func layerImage(_ l: Layer, state: DocumentState, space: CanvasSpace, contentOnly: Bool) throws -> CIImage {
        if RecipeAmbient.renderingLayers.contains(l.id) { throw RecipeError.message("Circular layer reference") }
        let clear = CIImage.clearImage.cropped(to: space.ciCanvas)
        var layer = l
        layer.isClipped = false
        layer.isVisible = true
        if l.isAdjustment { throw RecipeError.message("Adjustment layers have no pixels") }
        if contentOnly { return Compositor.shared.contentImage(layer, space: space) ?? clear }
        return Compositor.shared.composite(layers: [layer], backdrop: clear, space: space, options: Compositor.Options(globalLight: state.globalLight))
    }

    // MARK: Baking

    /// Replaces every Recipe layer with a pixel layer showing the same thing (for formats that can't store recipes).
    static func rasterizingRecipes(_ st: DocumentState) -> DocumentState {
        var out = st
        for l in st.allLayers {
            guard case .fill(let f) = l.content, f.recipe != nil else { continue }
            let r = Compositor.shared.rasterize(l, state: st, includeEffects: false)
            out.updateLayer(l.id) { $0.content = .raster(r) }
        }
        return out
    }
}
