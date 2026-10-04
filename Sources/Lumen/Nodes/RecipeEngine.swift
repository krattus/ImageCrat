import Foundation
import CoreImage
import ImageCratCore

// MARK: - Values

enum RecipeValue {
    case image(CIImage)       // premultiplied RGBA, extent = canvas
    case mask(CIImage)        // opaque gray, extent = canvas
    case number(Double)
    case color(RGBA)
    case vector(CGPoint)
    case gradient(ColorGradient)
    case curve(CurvePoints)

    var type: RecipePortType {
        switch self {
        case .image: return .image
        case .mask: return .mask
        case .number: return .number
        case .color: return .color
        case .vector: return .vector
        case .gradient: return .gradient
        case .curve: return .curve
        }
    }

    var ciImage: CIImage? {
        switch self {
        case .image(let i), .mask(let i): return i
        default: return nil
        }
    }

    /// Automatic conversion used when a wire joins ports of different types.
    func converted(to t: RecipePortType, canvas: CGRect) -> RecipeValue? {
        if type == t { return self }
        switch (self, t) {
        case (.number(let n), .color): return .color(RGBA(gray: n))
        case (.number(let n), .vector): return .vector(CGPoint(x: n, y: n))
        case (.number(let n), .image): return .image(RecipeKernels.constant(n, n, n, 1, canvas))
        case (.number(let n), .mask): return .mask(RecipeKernels.constant(n, n, n, 1, canvas))
        case (.color(let c), .number): return .number(c.luminance)
        case (.color(let c), .image): return .image(RecipeKernels.constant(c.r, c.g, c.b, c.a, canvas))
        case (.color(let c), .mask): let l = c.luminance * c.a; return .mask(RecipeKernels.constant(l, l, l, 1, canvas))
        case (.color(let c), .gradient): return .gradient(.twoColor(c, c, name: "Solid"))
        case (.vector(let v), .number): return .number(Double(v.x))
        case (.vector(let v), .image): return .image(RecipeKernels.constant(Double(v.x), Double(v.y), 0, 1, canvas))
        case (.image(let i), .mask):
            return .mask(RecipeKernels.toMask?.apply(extent: canvas, arguments: [i, 0]) ?? i)
        case (.mask(let m), .image): return .image(m)
        case (.gradient(let g), .image):
            return .image(Kernels.gradientImage(g, type: .linear, p0: CGPoint(x: canvas.minX, y: canvas.midY), p1: CGPoint(x: canvas.maxX, y: canvas.midY), reverse: false, extent: canvas))
        case (.gradient(let g), .color): return .color(g.color(at: 0.5))
        default: return nil
        }
    }
}

enum RecipeError: LocalizedError {
    case missingInput(String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .missingInput(let p): return "No \(p) input"
        case .message(let m): return m
        }
    }
}

// MARK: - Node specs

struct RecipePortSpec {
    let name: String
    let type: RecipePortType
    init(_ name: String, _ type: RecipePortType) { self.name = name; self.type = type }
}

enum RecipeParamKind {
    case slider(ClosedRange<Double>)
    case int(ClosedRange<Double>)
    case angle
    case toggle
    case choice([String])
    case seed
    case color
    case point            // normalized canvas position (0…1, y down)
    case gradient
    case curve
    case text
    case file
    case layer
}

struct RecipeParamSpec {
    let key: String
    let label: String
    let kind: RecipeParamKind
    var def: Double = 0
    var defColor: RGBA = .white
    var defPoint = CGPoint(x: 0.5, y: 0.5)
    var defGradient: ColorGradient? = nil
    var defString = ""
    var unit = ""
    /// Inspector-only (not drawn inside the node, not connectable).
    var advanced = false

    static func slider(_ key: String, _ label: String, _ r: ClosedRange<Double>, _ def: Double, unit: String = "") -> RecipeParamSpec {
        RecipeParamSpec(key: key, label: label, kind: .slider(r), def: def, unit: unit)
    }
    static func int(_ key: String, _ label: String, _ r: ClosedRange<Double>, _ def: Double) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .int(r), def: def) }
    static func angle(_ key: String, _ label: String, _ def: Double) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .angle, def: def, unit: "°") }
    static func toggle(_ key: String, _ label: String, _ def: Bool) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .toggle, def: def ? 1 : 0) }
    static func choice(_ key: String, _ label: String, _ opts: [String], _ def: Int = 0) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .choice(opts), def: Double(def)) }
    static func seed(_ key: String = "seed", _ label: String = "Seed", _ def: Double = 1) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .seed, def: def) }
    static func color(_ key: String, _ label: String, _ def: RGBA) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .color, defColor: def) }
    static func point(_ key: String, _ label: String, _ def: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .point, defPoint: def) }
    static func gradient(_ key: String, _ label: String, _ def: ColorGradient) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .gradient, defGradient: def) }
    static func curve(_ key: String, _ label: String) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .curve) }
    static func text(_ key: String, _ label: String, _ def: String = "") -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .text, defString: def) }
    static func file(_ key: String, _ label: String) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .file) }
    static func layer(_ key: String, _ label: String) -> RecipeParamSpec { RecipeParamSpec(key: key, label: label, kind: .layer) }

    /// Port type when the parameter can be driven by a wire ("p:<key>" input); nil = not connectable.
    var portType: RecipePortType? {
        switch kind {
        case .slider, .int, .angle, .seed: return .number
        case .color: return .color
        case .point: return .vector
        case .gradient: return .gradient
        case .curve: return .curve
        case .toggle, .choice, .text, .file, .layer: return nil
        }
    }

    var isNumeric: Bool {
        switch kind {
        case .slider, .int, .angle, .toggle, .choice, .seed: return true
        default: return false
        }
    }

    var range: ClosedRange<Double> {
        switch kind {
        case .slider(let r), .int(let r): return r
        case .angle: return -180...180
        case .toggle: return 0...1
        case .choice(let o): return 0...Double(max(0, o.count - 1))
        case .seed: return 0...9999
        default: return 0...1
        }
    }

    func sanitized(_ v: Double) -> Double {
        guard v.isFinite else { return def }
        switch kind {
        case .slider(let r): return min(max(v, r.lowerBound), r.upperBound)
        case .int(let r): return min(max(v.rounded(), r.lowerBound), r.upperBound)
        case .toggle: return v > 0.5 ? 1 : 0
        case .choice(let o): return min(max(v.rounded(), 0), Double(max(0, o.count - 1)))
        case .seed: return min(max(v.rounded(), 0), 99999)
        default: return v
        }
    }

    var portName: String { "p:" + key }

    func asAdvanced() -> RecipeParamSpec { var p = self; p.advanced = true; return p }
}

struct RecipeUses: OptionSet {
    let rawValue: Int
    /// Reads the layer-below / source image.
    static let source = RecipeUses(rawValue: 1)
    /// Reads the animation clock.
    static let time = RecipeUses(rawValue: 2)
    /// Reads other document state (layers, selection, masks): re-evaluated every time.
    static let document = RecipeUses(rawValue: 4)
}

enum RecipeCategory: String, CaseIterable {
    case input = "Input", generate = "Generate", adjust = "Adjust", filter = "Filter", composite = "Composite"
    case transform = "Transform", math = "Math", utility = "Utility", output = "Output"

    var symbol: String {
        switch self {
        case .input: return "square.and.arrow.down"
        case .generate: return "sparkles"
        case .adjust: return "slider.horizontal.3"
        case .filter: return "camera.filters"
        case .composite: return "square.on.square"
        case .transform: return "arrow.up.and.down.and.arrow.left.and.right"
        case .math: return "function"
        case .utility: return "wrench.and.screwdriver"
        case .output: return "square.and.arrow.up"
        }
    }

    /// Header tint of nodes in the editor.
    var rgba: RGBA {
        switch self {
        case .input: return RGBA(hex: "8A5A2B")!
        case .generate: return RGBA(hex: "2F6B5A")!
        case .adjust: return RGBA(hex: "6B5FA8")!
        case .filter: return RGBA(hex: "3D6FA8")!
        case .composite: return RGBA(hex: "8A4B7A")!
        case .transform: return RGBA(hex: "4F7D3A")!
        case .math: return RGBA(hex: "5A6470")!
        case .utility: return RGBA(hex: "A8683D")!
        case .output: return RGBA(hex: "A83D3D")!
        }
    }
}

struct RecipeNodeSpec {
    let type: String
    let name: String
    let category: RecipeCategory
    /// Sub-menu inside the category ("" = top level).
    var group = ""
    var inputs: [RecipePortSpec] = []
    var outputs: [RecipePortSpec] = [RecipePortSpec("Image", .image)]
    var params: [RecipeParamSpec] = []
    var uses: RecipeUses = []
    var keywords: [String] = []
    /// Input that a muted node passes through (nil: outputs nothing).
    var bypass: String? = nil
    var adjustmentKind: AdjustmentKind? = nil
    let eval: (inout RecipeEval) throws -> Void

    func param(_ key: String) -> RecipeParamSpec? { params.first { $0.key == key } }
}

// MARK: - Evaluation context

/// Everything a graph needs from its surroundings for one evaluation.
final class RecipeContext {
    let space: CanvasSpace
    /// Layer below / smart-object content (nil = nothing).
    var source: CIImage?
    /// Changes whenever `source` changes (cache key for nodes that read it).
    var sourceToken = 0
    /// Document being composited (layer references, selection, masks); nil when unknown.
    var state: DocumentState?
    /// The Recipe layer itself (its mask input, recursion guard).
    var layerID: UUID?
    var time: Double = 0
    var origin: CGPoint = .zero
    /// Unique per evaluation (nodes that read the document are never cached).
    var serial = 0

    init(space: CanvasSpace) { self.space = space }
    var canvas: CGRect { space.ciCanvas }
}

/// Per-node evaluation scratch passed to `RecipeNodeSpec.eval`.
struct RecipeEval {
    let node: RecipeNode
    let spec: RecipeNodeSpec
    let ctx: RecipeContext
    /// Values arriving on connected inputs, by port name (parameter ports are "p:<key>").
    var inputs: [String: RecipeValue] = [:]
    var out: [RecipeValue] = []

    var canvas: CGRect { ctx.canvas }
    var clear: CIImage { CIImage.clearImage.cropped(to: canvas) }

    func connected(_ port: String) -> Bool { inputs[port] != nil }

    func num(_ key: String) -> Double {
        guard let p = spec.param(key) else { return node.numbers[key] ?? 0 }
        if let v = inputs[p.portName]?.converted(to: .number, canvas: canvas), case .number(let n) = v { return p.sanitized(n) }
        return p.sanitized(node.numbers[key] ?? p.def)
    }
    func bool(_ key: String) -> Bool { num(key) > 0.5 }
    func int(_ key: String) -> Int { Int(num(key).rounded()) }

    func color(_ key: String) -> RGBA {
        let p = spec.param(key)
        if let p, let v = inputs[p.portName]?.converted(to: .color, canvas: canvas), case .color(let c) = v { return c }
        return node.colors[key] ?? p?.defColor ?? .white
    }

    func point(_ key: String) -> CGPoint {
        let p = spec.param(key)
        if let p, let v = inputs[p.portName]?.converted(to: .vector, canvas: canvas), case .vector(let c) = v { return c }
        return node.vectors[key] ?? p?.defPoint ?? CGPoint(x: 0.5, y: 0.5)
    }

    func gradient(_ key: String) -> ColorGradient {
        let p = spec.param(key)
        if let p, let v = inputs[p.portName]?.converted(to: .gradient, canvas: canvas), case .gradient(let g) = v { return g }
        return node.gradients[key] ?? p?.defGradient ?? .twoColor(.black, .white)
    }

    func curve(_ key: String) -> CurvePoints {
        if let p = spec.param(key), case .curve(let c)? = inputs[p.portName] { return c }
        return node.curves[key] ?? CurvePoints()
    }

    func string(_ key: String) -> String { node.strings[key] ?? spec.param(key)?.defString ?? "" }

    /// Normalized point parameter → CI-space point.
    func ciPoint(_ key: String) -> CGPoint {
        let p = point(key)
        return CGPoint(x: canvas.minX + p.x * canvas.width, y: canvas.maxY - p.y * canvas.height)
    }

    func image(_ port: String = "Image") -> CIImage? {
        guard let v = inputs[port]?.converted(to: .image, canvas: canvas), case .image(let i) = v else { return nil }
        return i
    }

    func mask(_ port: String = "Mask") -> CIImage? {
        guard let v = inputs[port]?.converted(to: .mask, canvas: canvas), case .mask(let i) = v else { return nil }
        return i
    }

    func need(_ port: String = "Image") throws -> CIImage {
        guard let i = image(port) else { throw RecipeError.missingInput(port) }
        return i
    }

    func needMask(_ port: String = "Mask") throws -> CIImage {
        guard let i = mask(port) else { throw RecipeError.missingInput(port) }
        return i
    }

    mutating func set(_ img: CIImage) { out = [.image(img)] }
    mutating func setMask(_ img: CIImage) { out = [.mask(img)] }
}

// MARK: - Evaluator

/// Evaluates a graph into a Core Image graph, caching per node. A node is re-evaluated only when its own values,
/// one of its upstream nodes, or the context it reads (source image, time, document) changed.
final class RecipeEvaluator {
    private struct InputKey: Equatable { var port: String; var from: UUID; var fromPort: String; var gen: Int }
    private struct Entry {
        var node: RecipeNode
        var inputs: [InputKey]
        var tokens: [Double]
        var gen: Int
        var outputs: [RecipeValue]
        var error: String?
    }

    private var entries: [UUID: Entry] = [:]
    private var genCounter = 0
    private var size = (0, 0)
    private var origin = CGPoint.zero
    /// Node ids re-evaluated by the most recent `evaluate` / `values` call (tests, profiling).
    private(set) var lastEvaluated: [UUID] = []
    /// Error messages by node id after the most recent evaluation.
    private(set) var errors: [UUID: String] = [:]
    /// Problem with the graph as a whole (no Output node…).
    private(set) var graphError: String?

    private var visiting = Set<UUID>()
    private var done = Set<UUID>()

    func reset() { entries.removeAll() }

    private func begin(_ graph: RecipeGraph, _ ctx: RecipeContext) {
        if size != (ctx.space.width, ctx.space.height) || origin != ctx.origin {
            entries.removeAll()
            size = (ctx.space.width, ctx.space.height)
            origin = ctx.origin
        }
        let ids = Set(graph.nodes.map(\.id))
        for k in entries.keys where !ids.contains(k) { entries.removeValue(forKey: k) }
        lastEvaluated = []
        visiting = []
        done = []
        graphError = nil
    }

    private func finish(_ graph: RecipeGraph) {
        errors = [:]
        for n in graph.nodes { if let e = entries[n.id]?.error { errors[n.id] = e } }
    }

    /// The graph's final image (Output node, or the soloed node), cropped to the canvas.
    func evaluate(_ graph: RecipeGraph, ctx: RecipeContext) -> CIImage {
        begin(graph, ctx)
        defer { finish(graph) }
        let clear = CIImage.clearImage.cropped(to: ctx.canvas)
        let target: UUID
        if let s = graph.solo, graph.node(s) != nil { target = s }
        else if let o = graph.outputNode { target = o.id }
        else { graphError = "The recipe has no Output node."; return clear }
        let e = resolve(target, graph, ctx)
        guard let first = e.outputs.first, let v = first.converted(to: .image, canvas: ctx.canvas), case .image(let img) = v else { return clear }
        return img
    }

    /// Outputs of one node (evaluating it and its upstream if needed) — used for node previews.
    func values(of node: UUID, _ graph: RecipeGraph, ctx: RecipeContext) -> [RecipeValue] {
        begin(graph, ctx)
        defer { finish(graph) }
        return resolve(node, graph, ctx).outputs
    }

    /// Evaluates every node (previews of unconnected branches, error badges).
    func evaluateAll(_ graph: RecipeGraph, ctx: RecipeContext) -> [UUID: [RecipeValue]] {
        begin(graph, ctx)
        defer { finish(graph) }
        var out: [UUID: [RecipeValue]] = [:]
        for n in graph.nodes { out[n.id] = resolve(n.id, graph, ctx).outputs }
        return out
    }

    /// Cached outputs from the latest evaluation (nil when the node was not reached).
    func cachedOutputs(_ node: UUID) -> [RecipeValue]? { entries[node]?.outputs }

    private func resolve(_ id: UUID, _ graph: RecipeGraph, _ ctx: RecipeContext) -> Entry {
        if done.contains(id), let e = entries[id] { return e }
        guard let node = graph.node(id) else {
            return Entry(node: RecipeNode(type: "missing"), inputs: [], tokens: [], gen: 0, outputs: [], error: "Missing node")
        }
        if visiting.contains(id) {
            return Entry(node: node, inputs: [], tokens: [], gen: 0, outputs: [], error: "Loop")
        }
        visiting.insert(id)
        defer { visiting.remove(id); done.insert(id) }

        let spec = RecipeLibrary.spec(node.type)
        // Upstream first.
        var keys: [InputKey] = []
        var values: [String: RecipeValue] = [:]
        for c in graph.connections where c.to == id {
            let up = resolve(c.from, graph, ctx)
            keys.append(InputKey(port: c.toPort, from: c.from, fromPort: c.fromPort, gen: up.gen))
            if let upNode = graph.node(c.from), let idx = RecipeLibrary.outputIndex(upNode, c.fromPort), idx < up.outputs.count {
                values[c.toPort] = up.outputs[idx]
            }
        }
        keys.sort { $0.port < $1.port }
        var tokens: [Double] = []
        if let s = spec {
            if s.uses.contains(.source) { tokens.append(Double(ctx.sourceToken)) }
            if s.uses.contains(.time) { tokens.append(ctx.time) }
            if s.uses.contains(.document) { tokens.append(Double(ctx.serial)) }
        }
        if let e = entries[id], e.node.sameValues(as: node), e.inputs == keys, e.tokens == tokens {
            return e
        }

        genCounter += 1
        var entry = Entry(node: node, inputs: keys, tokens: tokens, gen: genCounter, outputs: [], error: nil)
        lastEvaluated.append(id)
        guard let spec else {
            entry.error = "Unknown node type “\(node.type)”"
            // pass the first image through so newer graphs still show something
            if let v = values.first(where: { $0.value.ciImage != nil })?.value { entry.outputs = [v] }
            entries[id] = entry
            return entry
        }
        var ev = RecipeEval(node: node, spec: spec, ctx: ctx, inputs: values)
        if node.muted {
            entry.outputs = bypassOutputs(spec, ev)
        } else {
            do {
                try spec.eval(&ev)
                entry.outputs = ev.out
            } catch {
                entry.error = error.localizedDescription
                entry.outputs = bypassOutputs(spec, ev)
            }
        }
        entry.outputs = normalize(entry.outputs, spec: spec, canvas: ctx.canvas)
        entries[id] = entry
        return entry
    }

    /// What a muted (or failed) node outputs: its bypass input on every image output, transparent otherwise.
    private func bypassOutputs(_ spec: RecipeNodeSpec, _ ev: RecipeEval) -> [RecipeValue] {
        let clear = CIImage.clearImage.cropped(to: ev.canvas)
        let black = CIImage.color(.black, ev.canvas)
        return spec.outputs.map { o in
            switch o.type {
            case .image:
                if let b = spec.bypass, let i = ev.image(b) { return .image(i) }
                return .image(clear)
            case .mask:
                if let b = spec.bypass, let i = ev.mask(b) { return .mask(i) }
                return .mask(black)
            case .number: return .number(0)
            case .color: return .color(.black)
            case .vector: return .vector(.zero)
            case .gradient: return .gradient(.twoColor(.black, .white))
            case .curve: return .curve(CurvePoints())
            }
        }
    }

    /// Pads / crops image outputs to the canvas and fills in missing outputs.
    private func normalize(_ outs: [RecipeValue], spec: RecipeNodeSpec, canvas: CGRect) -> [RecipeValue] {
        var r: [RecipeValue] = []
        for (i, o) in spec.outputs.enumerated() {
            let v: RecipeValue? = i < outs.count ? outs[i].converted(to: o.type, canvas: canvas) : nil
            switch v {
            case .image(let img)?: r.append(.image(RecipeEvaluator.fit(img, canvas, opaqueBlack: false)))
            case .mask(let img)?: r.append(.mask(RecipeEvaluator.fit(img, canvas, opaqueBlack: true)))
            case let other?: r.append(other)
            case nil:
                switch o.type {
                case .image: r.append(.image(CIImage.clearImage.cropped(to: canvas)))
                case .mask: r.append(.mask(CIImage.color(.black, canvas)))
                case .number: r.append(.number(0))
                case .color: r.append(.color(.black))
                case .vector: r.append(.vector(.zero))
                case .gradient: r.append(.gradient(.twoColor(.black, .white)))
                case .curve: r.append(.curve(CurvePoints()))
                }
            }
        }
        return r
    }

    /// Image with extent exactly `canvas`.
    static func fit(_ img: CIImage, _ canvas: CGRect, opaqueBlack: Bool) -> CIImage {
        let e = img.extent
        if e == canvas { return img }
        if !e.isInfinite && !e.contains(canvas) {
            let bg = opaqueBlack ? CIImage.color(.black, canvas) : CIImage.clearImage.cropped(to: canvas)
            return img.composited(over: bg).cropped(to: canvas)
        }
        return img.cropped(to: canvas)
    }
}
