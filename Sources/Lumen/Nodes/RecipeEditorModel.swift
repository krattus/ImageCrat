import AppKit
import CoreImage
import Observation
import ImageCratCore

/// State and commands of the Recipe Editor. The graph itself lives in the document (so every edit is a normal history
/// step and undo / redo just work); this object only holds view state and transient drags.
@Observable
final class RecipeEditorModel {
    struct WireDrag {
        var node: UUID
        var port: String
        /// True: dragging from an output towards an input. False: dragging from an input back to an output.
        var fromOutput: Bool
        var type: RecipePortType
        var point: CGPoint     // graph coordinates
    }

    struct SearchState {
        var position: CGPoint          // graph coordinates where the node will be placed
        var query = ""
        var index = 0
        /// When opened by dropping a wire on empty canvas: the loose end to connect the new node to.
        var pending: WireDrag? = nil
    }

    enum AlignMode { case left, right, top, bottom, hCenter, vCenter, distributeH, distributeV }

    @ObservationIgnored weak var document: Document?
    var target: RecipeTarget

    // View state
    var pan = CGPoint(x: 30, y: 30)
    var zoom: CGFloat = 1
    var viewSize = CGSize(width: 900, height: 600)
    var selection = Set<UUID>()
    var selectedFrame: UUID? = nil
    /// Live offset of the nodes being dragged (graph units); written to the graph on release.
    var dragOffset: CGSize? = nil
    var draggingFrame: UUID? = nil
    /// Frame being resized by its corner grip (`dragOffset` is the size change).
    var resizingFrame: UUID? = nil
    var wire: WireDrag? = nil
    var box: CGRect? = nil            // box selection in graph coordinates
    var search: SearchState? = nil
    var mouseView = CGPoint(x: 200, y: 160)
    var hovering = false
    var status = ""
    var previews: [UUID: CGImage] = [:]
    var errors: [UUID: String] = [:]
    var graphError: String? = nil
    /// Inspector: which parameter editor popover is open etc.
    var renamingFrame: UUID? = nil
    /// The view fits the graph once, the first time it appears.
    @ObservationIgnored var didInitialFit = false

    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var previewWork: DispatchWorkItem?
    @ObservationIgnored private var lastPreviewSignature = ""
    private static let previewQueue = DispatchQueue(label: "app.lumen.recipe.previews", qos: .userInitiated)

    init(document: Document, target: RecipeTarget) {
        self.document = document
        self.target = target
    }

    // MARK: Graph access

    var graph: RecipeGraph? { document?.state.recipeGraph(target) }
    var exists: Bool { graph != nil }

    var title: String {
        guard let d = document, let l = d.state.layer(target.layerID) else { return "Recipe Editor" }
        if case .smartFilter = target { return "Recipe Filter — \(l.name)" }
        return "Recipe — \(l.name)"
    }

    /// Applies an edit. `commit: nil` leaves it uncommitted (live drags); otherwise records one history step.
    func mutate(_ name: String?, _ body: (inout RecipeGraph) -> Void) {
        guard let d = document else { return }
        RecipeActions.mutate(d, target, commit: name.map { "Recipe: " + $0 }, body)
        schedulePreviews()
    }

    func commit(_ name: String) {
        document?.commit("Recipe: " + name)
        schedulePreviews()
    }

    // MARK: Coordinates

    func toGraph(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y) }
    var mouseGraph: CGPoint { toGraph(mouseView) }

    func zoom(by factor: CGFloat, around p: CGPoint? = nil) {
        let anchor = p ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let g = toGraph(anchor)
        zoom = min(max(zoom * factor, 0.2), 2.5)
        pan = CGPoint(x: anchor.x - g.x * zoom, y: anchor.y - g.y * zoom)
    }

    func bounds(of ids: Set<UUID>? = nil) -> CGRect? {
        guard let g = graph else { return nil }
        var r = CGRect.null
        for n in g.nodes where ids == nil || ids!.contains(n.id) { r = r.union(CGRect(origin: n.position, size: RecipeLibrary.nodeSize(n))) }
        if ids == nil { for f in g.frames { r = r.union(f.rect) } }
        return r.isNull ? nil : r
    }

    func fitView() {
        guard let b = bounds(), viewSize.width > 50 else { return }
        let z = min((viewSize.width - 60) / max(b.width, 1), (viewSize.height - 60) / max(b.height, 1))
        zoom = min(max(z, 0.5), 1)      // never so small that nodes become unreadable; scroll to see the rest
        let w = b.width * zoom, h = b.height * zoom
        pan = CGPoint(x: (w <= viewSize.width - 40 ? (viewSize.width - w) / 2 : 24) - b.minX * zoom,
                      y: (h <= viewSize.height - 40 ? (viewSize.height - h) / 2 : 24) - b.minY * zoom)
    }

    /// Node position including the live drag offset.
    func position(_ n: RecipeNode) -> CGPoint {
        if resizingFrame != nil { return n.position }
        if let o = dragOffset, draggingFrame == nil, selection.contains(n.id) { return CGPoint(x: n.position.x + o.width, y: n.position.y + o.height) }
        if let o = dragOffset, let fid = draggingFrame, let f = graph?.frames.first(where: { $0.id == fid }), f.rect.contains(CGPoint(x: n.position.x + 10, y: n.position.y + 10)) {
            return CGPoint(x: n.position.x + o.width, y: n.position.y + o.height)
        }
        return n.position
    }

    private func placed(_ n: RecipeNode) -> RecipeNode { var m = n; m.position = position(n); return m }
    func outputPoint(_ n: RecipeNode, _ port: String) -> CGPoint { RecipeLibrary.outputPosition(placed(n), port) }
    func inputPoint(_ n: RecipeNode, _ port: String) -> CGPoint { RecipeLibrary.inputPosition(placed(n), port) }

    // MARK: Selection

    func select(_ id: UUID, extend: Bool) {
        focusCanvas()
        selectedFrame = nil
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
    }

    func selectOnly(_ id: UUID) { selection = [id]; selectedFrame = nil }
    func clearSelection() { focusCanvas(); selection = []; selectedFrame = nil }
    func selectAll() { selection = Set(graph?.nodes.map(\.id) ?? []) }

    func finishBox(extend: Bool) {
        guard let b = box, let g = graph else { box = nil; return }
        let hit = Set(g.nodes.filter { CGRect(origin: $0.position, size: RecipeLibrary.nodeSize($0)).intersects(b) }.map(\.id))
        selection = extend ? selection.union(hit) : hit
        box = nil
    }

    var singleSelection: RecipeNode? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return graph?.node(id)
    }

    // MARK: Nodes

    /// Adds a node (top-left at `p`). Returns its id.
    @discardableResult
    func addNode(_ type: String, at p: CGPoint, connecting pending: WireDrag? = nil) -> UUID? {
        guard RecipeLibrary.spec(type) != nil, exists else { return nil }
        var n = RecipeLibrary.makeNode(type, at: CGPoint(x: (p.x / 10).rounded() * 10, y: (p.y / 10).rounded() * 10))
        if type == "in.layer", let d = document {
            // default to the layer below the recipe layer, if any
            let sib = d.state.siblings(of: target.layerID)
            if let i = sib.firstIndex(where: { $0.id == target.layerID }), i > 0 { n.strings["layer"] = sib[i - 1].id.uuidString }
        }
        let id = n.id
        mutate("Add \(RecipeLibrary.spec(type)?.name ?? "Node")") { g in
            g.nodes.append(n)
            if let w = pending { RecipeEditorModel.autoConnect(&g, new: n, to: w) }
        }
        selection = [id]
        selectedFrame = nil
        return id
    }

    /// Connects a freshly added node to the loose end of a dropped wire (first compatible port).
    static func autoConnect(_ g: inout RecipeGraph, new n: RecipeNode, to w: WireDrag) {
        guard let spec = RecipeLibrary.spec(n.type) else { return }
        if w.fromOutput {
            if let p = spec.inputs.first(where: { w.type.canConvert(to: $0.type) }) { _ = try? g.connect(from: w.node, w.port, to: n.id, p.name) }
            else if let p = RecipeLibrary.bodyParams(spec).first(where: { p in p.portType.map { w.type.canConvert(to: $0) } ?? false }) {
                _ = try? g.connect(from: w.node, w.port, to: n.id, p.portName)
            }
        } else if let o = spec.outputs.first(where: { $0.type.canConvert(to: w.type) }) {
            _ = try? g.connect(from: n.id, o.name, to: w.node, w.port)
        }
    }

    func deleteSelection() {
        if let f = selectedFrame { mutate("Delete Frame") { $0.frames.removeAll { $0.id == f } }; selectedFrame = nil; return }
        guard !selection.isEmpty else { return }
        let ids = selection
        mutate(ids.count == 1 ? "Delete Node" : "Delete Nodes") { $0.removeNodes(ids) }
        selection = []
    }

    func duplicateSelection() {
        guard let g = graph, !selection.isEmpty else { return }
        let (nodes, wires) = g.duplicate(selection, offset: CGPoint(x: 30, y: 30))
        mutate("Duplicate") { g in
            g.nodes.append(contentsOf: nodes.filter { $0.type != RecipeLibrary.outputNodeType || g.outputNode == nil })
            let ids = Set(g.nodes.map(\.id))
            g.connections.append(contentsOf: wires.filter { ids.contains($0.from) && ids.contains($0.to) })
        }
        selection = Set(nodes.map(\.id)).intersection(Set(graph?.nodes.map(\.id) ?? []))
    }

    // MARK: Clipboard

    static let pasteboardType = NSPasteboard.PasteboardType("app.lumen.recipe-nodes")

    struct Clip: Codable { var nodes: [RecipeNode]; var connections: [RecipeConnection] }

    func copySelection() {
        guard let g = graph, !selection.isEmpty else { return }
        let clip = Clip(nodes: g.nodes.filter { selection.contains($0.id) }, connections: g.connections.filter { selection.contains($0.to) })
        guard let data = try? JSONEncoder().encode(clip) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        status = "Copied \(clip.nodes.count) node\(clip.nodes.count == 1 ? "" : "s")"
    }

    func cutSelection() { copySelection(); deleteSelection() }

    var canPaste: Bool { NSPasteboard.general.data(forType: Self.pasteboardType) != nil }

    /// Pastes copied nodes with their top-left at `p` (default: the mouse).
    func paste(at p: CGPoint? = nil) {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType), let clip = try? JSONDecoder().decode(Clip.self, from: data), !clip.nodes.isEmpty else { return }
        pasteClip(clip, at: p ?? mouseGraph)
    }

    func pasteClip(_ clip: Clip, at p: CGPoint) {
        guard exists else { return }
        let minX = clip.nodes.map(\.position.x).min() ?? 0, minY = clip.nodes.map(\.position.y).min() ?? 0
        var map: [UUID: UUID] = [:]
        var nodes: [RecipeNode] = []
        for n in clip.nodes {
            var c = n
            c.id = UUID()
            c.position = CGPoint(x: p.x + n.position.x - minX, y: p.y + n.position.y - minY)
            map[n.id] = c.id
            nodes.append(c)
        }
        mutate("Paste") { g in
            for n in nodes where n.type != RecipeLibrary.outputNodeType || g.outputNode == nil { g.nodes.append(n) }
            let ids = Set(g.nodes.map(\.id))
            for c in clip.connections {
                guard let to = map[c.to], ids.contains(to) else { continue }
                let from = map[c.from] ?? c.from        // wires from outside the copied set keep their source if it still exists
                if ids.contains(from) { _ = try? g.connect(from: from, c.fromPort, to: to, c.toPort) }
            }
        }
        selection = Set(nodes.map(\.id)).intersection(Set(graph?.nodes.map(\.id) ?? []))
    }

    // MARK: Wires

    /// Tries to connect; returns false (with a status message) when the graph refuses.
    @discardableResult
    func connect(from: UUID, _ fromPort: String, to: UUID, _ toPort: String) -> Bool {
        guard var g = graph else { return false }
        do {
            try g.connect(from: from, fromPort, to: to, toPort)
        } catch {
            status = error.localizedDescription
            Beep.play()
            return false
        }
        mutate("Connect") { $0 = g }
        if let a = g.node(from), let b = g.node(to), let ot = RecipeLibrary.outputType(a, fromPort), let it = RecipeLibrary.inputType(b, toPort), ot != it {
            status = "Connected (\(ot.displayName) → \(it.displayName) conversion)"
        } else { status = "Connected" }
        return true
    }

    func disconnect(_ id: UUID) { mutate("Disconnect") { $0.disconnect(id) } }

    func disconnectAll(_ node: UUID) { mutate("Disconnect") { g in g.connections.removeAll { $0.from == node || $0.to == node } } }

    /// Nearest compatible port to a graph point, for finishing a wire drag.
    func portHit(_ p: CGPoint, for w: WireDrag) -> (node: UUID, port: String)? {
        guard let g = graph else { return nil }
        var best: (UUID, String, CGFloat)? = nil
        let radius: CGFloat = 16
        for n in g.nodes where n.id != w.node {
            guard let spec = RecipeLibrary.spec(n.type) else { continue }
            if w.fromOutput {
                var ports = spec.inputs.map { ($0.name, $0.type) }
                if !n.collapsed { for prm in RecipeLibrary.bodyParams(spec) { if let t = prm.portType { ports.append((prm.portName, t)) } } }
                for (name, t) in ports where w.type.canConvert(to: t) {
                    let q = inputPoint(n, name)
                    let d = hypot(q.x - p.x, q.y - p.y)
                    if d < radius, d < (best?.2 ?? .infinity) { best = (n.id, name, d) }
                }
                // dropping anywhere on a node body connects to its first free compatible input
                if best == nil, CGRect(origin: position(n), size: RecipeLibrary.nodeSize(n)).contains(p) {
                    if let free = ports.first(where: { w.type.canConvert(to: $0.1) && g.input(n.id, $0.0) == nil }) ?? ports.first(where: { w.type.canConvert(to: $0.1) }) {
                        best = (n.id, free.0, radius)
                    }
                }
            } else {
                for o in spec.outputs where o.type.canConvert(to: w.type) {
                    let q = outputPoint(n, o.name)
                    let d = hypot(q.x - p.x, q.y - p.y)
                    if d < radius, d < (best?.2 ?? .infinity) { best = (n.id, o.name, d) }
                }
                if best == nil, CGRect(origin: position(n), size: RecipeLibrary.nodeSize(n)).contains(p), let o = spec.outputs.first(where: { $0.type.canConvert(to: w.type) }) {
                    best = (n.id, o.name, radius)
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Starts dragging from a socket. Dragging from a connected input picks the existing wire up (detaches it).
    func beginWire(node: UUID, port: String, isOutput: Bool, at p: CGPoint) {
        guard let g = graph, let n = g.node(node) else { return }
        if isOutput {
            guard let t = RecipeLibrary.outputType(n, port) else { return }
            wire = WireDrag(node: node, port: port, fromOutput: true, type: t, point: p)
        } else if let c = g.input(node, port), let src = g.node(c.from), let t = RecipeLibrary.outputType(src, c.fromPort) {
            // re-route: remove (uncommitted) and continue from the source output
            mutate(nil) { $0.disconnect(c.id) }
            wire = WireDrag(node: c.from, port: c.fromPort, fromOutput: true, type: t, point: p)
        } else if let t = RecipeLibrary.inputType(n, port) {
            wire = WireDrag(node: node, port: port, fromOutput: false, type: t, point: p)
        }
    }

    func endWire(at p: CGPoint) {
        guard let w = wire else { return }
        wire = nil
        if let hit = portHit(p, for: w) {
            let ok = w.fromOutput ? connect(from: w.node, w.port, to: hit.node, hit.port) : connect(from: hit.node, hit.port, to: w.node, w.port)
            if !ok { document?.revertUncommitted() }
            return
        }
        // Dropped on empty canvas: a picked-up wire is deleted; a fresh wire opens the node search to add a node there.
        if let d = document, let g = graph, let committed = d.committedState.recipeGraph(target), committed.connections.count != g.connections.count {
            commit("Disconnect")
            return
        }
        search = SearchState(position: p, pending: w)
    }

    // MARK: Moving

    func endNodeDrag() {
        guard let o = dragOffset else { return }
        let ids = selection
        dragOffset = nil
        guard abs(o.width) > 0.5 || abs(o.height) > 0.5 else { return }
        mutate(ids.count == 1 ? "Move Node" : "Move Nodes") { g in
            for i in g.nodes.indices where ids.contains(g.nodes[i].id) {
                g.nodes[i].position = CGPoint(x: ((g.nodes[i].position.x + o.width) / 10).rounded() * 10, y: ((g.nodes[i].position.y + o.height) / 10).rounded() * 10)
            }
        }
    }

    func endFrameDrag() {
        guard let o = dragOffset, let fid = draggingFrame else { dragOffset = nil; draggingFrame = nil; return }
        dragOffset = nil
        draggingFrame = nil
        guard abs(o.width) > 0.5 || abs(o.height) > 0.5 else { return }
        mutate("Move Frame") { g in
            guard let fi = g.frames.firstIndex(where: { $0.id == fid }) else { return }
            let r = g.frames[fi].rect
            for i in g.nodes.indices where r.contains(CGPoint(x: g.nodes[i].position.x + 10, y: g.nodes[i].position.y + 10)) {
                g.nodes[i].position = CGPoint(x: g.nodes[i].position.x + o.width, y: g.nodes[i].position.y + o.height)
            }
            g.frames[fi].rect = r.offsetBy(dx: o.width, dy: o.height)
        }
    }

    func align(_ mode: AlignMode) {
        guard let g = graph, selection.count >= 2 else { return }
        let nodes = g.nodes.filter { selection.contains($0.id) }
        let rects = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGRect(origin: $0.position, size: RecipeLibrary.nodeSize($0))) })
        let all = rects.values.reduce(CGRect.null) { $0.union($1) }
        mutate("Align") { g in
            switch mode {
            case .left: for i in g.nodes.indices where rects[g.nodes[i].id] != nil { g.nodes[i].position.x = all.minX }
            case .right: for i in g.nodes.indices { if let r = rects[g.nodes[i].id] { g.nodes[i].position.x = all.maxX - r.width } }
            case .top: for i in g.nodes.indices where rects[g.nodes[i].id] != nil { g.nodes[i].position.y = all.minY }
            case .bottom: for i in g.nodes.indices { if let r = rects[g.nodes[i].id] { g.nodes[i].position.y = all.maxY - r.height } }
            case .hCenter: for i in g.nodes.indices { if let r = rects[g.nodes[i].id] { g.nodes[i].position.x = all.midX - r.width / 2 } }
            case .vCenter: for i in g.nodes.indices { if let r = rects[g.nodes[i].id] { g.nodes[i].position.y = all.midY - r.height / 2 } }
            case .distributeH:
                let sorted = nodes.sorted { $0.position.x < $1.position.x }
                guard sorted.count >= 3 else { return }
                let total = sorted.reduce(0) { $0 + rects[$1.id]!.width }
                let gap = (all.width - total) / CGFloat(sorted.count - 1)
                var x = all.minX
                for n in sorted { if let i = g.index(n.id) { g.nodes[i].position.x = x }; x += rects[n.id]!.width + gap }
            case .distributeV:
                let sorted = nodes.sorted { $0.position.y < $1.position.y }
                guard sorted.count >= 3 else { return }
                let total = sorted.reduce(0) { $0 + rects[$1.id]!.height }
                let gap = (all.height - total) / CGFloat(sorted.count - 1)
                var y = all.minY
                for n in sorted { if let i = g.index(n.id) { g.nodes[i].position.y = y }; y += rects[n.id]!.height + gap }
            }
        }
    }

    // MARK: Node flags

    func toggleMute() {
        guard !selection.isEmpty else { return }
        let ids = selection
        mutate("Mute") { g in for i in g.nodes.indices where ids.contains(g.nodes[i].id) { g.nodes[i].muted.toggle() } }
    }

    /// "View this node": shows the node's output on the canvas instead of the Output node (again to turn off).
    func toggleSolo(_ id: UUID?) {
        guard let nid = id else { mutate("View Output") { $0.solo = nil }; return }
        mutate("View Node") { g in g.solo = g.solo == nid || g.node(nid)?.type == RecipeLibrary.outputNodeType ? nil : nid }
    }

    func toggleCollapse() {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutate("Collapse") { g in for i in g.nodes.indices where ids.contains(g.nodes[i].id) { g.nodes[i].collapsed.toggle() } }
    }

    func togglePreview() {
        let ids = selection
        guard !ids.isEmpty else { return }
        mutate("Toggle Preview") { g in for i in g.nodes.indices where ids.contains(g.nodes[i].id) { g.nodes[i].showPreview.toggle() } }
    }

    // MARK: Frames

    func addFrame() {
        let r: CGRect
        if let b = bounds(of: selection), !selection.isEmpty { r = b.insetBy(dx: -18, dy: -22).offsetBy(dx: 0, dy: -10) }
        else { r = CGRect(origin: mouseGraph, size: CGSize(width: 320, height: 220)) }
        let f = RecipeFrame(title: "Frame", rect: r)
        mutate("Add Frame") { $0.frames.append(f) }
        selectedFrame = f.id
        selection = []
    }

    /// Frame rect including a live move / resize.
    func rect(_ f: RecipeFrame) -> CGRect {
        guard let o = dragOffset else { return f.rect }
        if resizingFrame == f.id { return CGRect(x: f.rect.minX, y: f.rect.minY, width: max(100, f.rect.width + o.width), height: max(70, f.rect.height + o.height)) }
        if draggingFrame == f.id { return f.rect.offsetBy(dx: o.width, dy: o.height) }
        return f.rect
    }

    func frameGripHit(_ p: CGPoint) -> UUID? {
        guard let g = graph else { return nil }
        return g.frames.reversed().first { CGRect(x: $0.rect.maxX - 16, y: $0.rect.maxY - 16, width: 20, height: 20).contains(p) }?.id
    }

    func endFrameResize() {
        guard let fid = resizingFrame, let f = graph?.frames.first(where: { $0.id == fid }) else { dragOffset = nil; resizingFrame = nil; return }
        let r = rect(f)
        dragOffset = nil
        resizingFrame = nil
        guard r != f.rect else { return }
        mutate("Resize Frame") { g in if let i = g.frames.firstIndex(where: { $0.id == fid }) { g.frames[i].rect = r } }
    }

    /// Gives keyboard focus back to the canvas (so Delete / shortcuts act on nodes, not on a text field).
    func focusCanvas() {
        if let p = RecipeEditorWindow.shared.panel, p.firstResponder is NSText { p.makeFirstResponder(nil) }
    }

    func frameTitleHit(_ p: CGPoint) -> UUID? {
        guard let g = graph else { return nil }
        return g.frames.reversed().first { CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: 22).contains(p) }?.id
    }

    // MARK: Exposed parameters

    func isExposed(_ node: UUID, _ key: String) -> Bool { graph?.exposed.contains { $0.node == node && $0.key == key } ?? false }

    func toggleExposed(_ node: UUID, _ key: String) {
        guard let g = graph, let n = g.node(node), let p = RecipeLibrary.spec(n.type)?.param(key) else { return }
        if isExposed(node, key) {
            mutate("Hide Parameter") { $0.exposed.removeAll { $0.node == node && $0.key == key } }
        } else {
            mutate("Expose Parameter") { $0.exposed.append(RecipeExposed(node: node, key: key, label: p.label)) }
        }
    }

    // MARK: Parameters (live + commit)

    func setNumber(_ node: UUID, _ key: String, _ v: Double) { mutate(nil) { $0.update(node) { $0.numbers[key] = v } } }
    func setColor(_ node: UUID, _ key: String, _ v: RGBA) { mutate(nil) { $0.update(node) { $0.colors[key] = v } } }
    func setPoint(_ node: UUID, _ key: String, _ v: CGPoint) { mutate(nil) { $0.update(node) { $0.vectors[key] = v } } }
    func setGradient(_ node: UUID, _ key: String, _ v: ColorGradient) { mutate(nil) { $0.update(node) { $0.gradients[key] = v } } }
    func setCurve(_ node: UUID, _ key: String, _ v: CurvePoints) { mutate(nil) { $0.update(node) { $0.curves[key] = v } } }
    func setString(_ node: UUID, _ key: String, _ v: String) { mutate(nil) { $0.update(node) { $0.strings[key] = v } } }

    // MARK: Presets

    func loadPreset(_ p: RecipePreset) {
        var g = p.graph
        RecipeActions.regenerateIDs(&g)
        if let old = graph { g.origin = old.origin }
        mutate("Load “\(p.name)”") { $0 = g }
        selection = []
        fitView()
    }

    func saveAsPreset(name: String) {
        guard let g = graph else { return }
        do {
            let p = try RecipePresetStore.shared.save(name: name, graph: g)
            status = p.url != nil ? "Saved “\(p.name)” to the recipe library" : "Saved “\(p.name)” (this session only)"
        } catch { status = "Could not save: \(error.localizedDescription)" }
    }

    // MARK: Previews

    /// Renders node thumbnails in the background (debounced; stale results are dropped).
    func schedulePreviews(delay: Double = 0.12) {
        previewWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshPreviews() }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Evaluates every node and renders thumbnails. `synchronous` is used by tests / offscreen snapshots.
    func refreshPreviews(synchronous: Bool = false) {
        guard let d = document, let g = graph else { previews = [:]; errors = [:]; return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let values = RecipeRuntime.shared.allValues(target: target.cacheID, graph: g, fallbackSpace: space)
        errors = RecipeRuntime.shared.errors(target: target.cacheID)
        graphError = g.outputNode == nil ? "No Output node — add one from Add ▸ Output." : nil
        previewGeneration += 1
        let gen = previewGeneration
        var jobs: [(UUID, CIImage)] = []
        for n in g.nodes where RecipeLibrary.hasPreview(n) {
            guard let outs = values[n.id], let img = outs.compactMap(\.ciImage).first else { continue }
            jobs.append((n.id, img))
        }
        let maxW = (RecipeLayout.width - 12) * 2, maxH = (RecipeLayout.previewHeight - 8) * 2
        let s = min(maxW / CGFloat(space.width), maxH / CGFloat(space.height))
        let outRect = CGRect(x: 0, y: 0, width: max(1, (CGFloat(space.width) * s).rounded()), height: max(1, (CGFloat(space.height) * s).rounded()))
        let canvas = space.ciCanvas
        let render: (CIImage) -> CGImage? = { img in
            let scaled = img.cropped(to: canvas).transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
            return RenderEngine.readbackContext.createCGImage(scaled, from: outRect, format: .RGBA8, colorSpace: sRGBSpace)
        }
        let keep = Set(g.nodes.map(\.id))
        if synchronous {
            var out: [UUID: CGImage] = [:]
            for (id, img) in jobs { if let cg = render(img) { out[id] = cg } }
            previews = out
            return
        }
        Self.previewQueue.async { [weak self] in
            var out: [UUID: CGImage] = [:]
            for (id, img) in jobs {
                if self?.previewGeneration != gen { return }
                if let cg = render(img) { out[id] = cg }
            }
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == gen else { return }
                var merged = self.previews.filter { keep.contains($0.key) }
                for (k, v) in out { merged[k] = v }
                self.previews = merged
            }
        }
    }

    // MARK: Keyboard

    /// Handles editor shortcuts. Returns true when the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        if search != nil {
            if e.keyCode == 53 { search = nil; return true }
            return false
        }
        if cmd {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "c": copySelection(); return true
            case "x": cutSelection(); return true
            case "v": paste(); return true
            case "d": duplicateSelection(); return true
            case "a": selectAll(); return true
            case "g": addFrame(); return true
            case "0": fitView(); return true
            case "=", "+": zoom(by: 1.25); return true
            case "-": zoom(by: 0.8); return true
            default: return false
            }
        }
        switch e.keyCode {
        case 48: search = SearchState(position: mouseGraph); return true          // Tab
        case 51, 117: deleteSelection(); return true                                  // Delete
        case 53: clearSelection(); wire = nil; return true                           // Esc
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "m": toggleMute(); return true
        case "v": toggleSolo(shift ? nil : selection.first); return true
        case "h": toggleCollapse(); return true
        case "p": togglePreview(); return true
        case "f": fitView(); return true
        case "a" where shift: search = SearchState(position: mouseGraph); return true
        default: return false
        }
    }
}
