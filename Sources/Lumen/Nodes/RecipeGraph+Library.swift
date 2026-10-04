import Foundation
import CoreGraphics
import ImageCratCore

// Graph operations that need the node catalogue (`RecipeLibrary`, which carries the Core Image evaluators).
extension RecipeGraph {
    var outputNode: RecipeNode? { nodes.first { $0.type == RecipeLibrary.outputNodeType } }
    /// Validates and adds a wire (replacing whatever fed that input). Throws on cycles / incompatible types.
    @discardableResult
    mutating func connect(from: UUID, _ fromPort: String, to: UUID, _ toPort: String) throws -> RecipeConnection {
        guard from != to else { throw RecipeGraphError.sameNode }
        guard let a = node(from), let b = node(to),
              let outT = RecipeLibrary.outputType(a, fromPort), let inT = RecipeLibrary.inputType(b, toPort) else { throw RecipeGraphError.unknownPort }
        guard outT.canConvert(to: inT) else { throw RecipeGraphError.incompatible(outT, inT) }
        if wouldCreateCycle(from: from, to: to) { throw RecipeGraphError.cycle }
        connections.removeAll { $0.to == to && $0.toPort == toPort }
        let c = RecipeConnection(from: from, fromPort: fromPort, to: to, toPort: toPort)
        connections.append(c)
        return c
    }
}

// MARK: - Builder (presets, tests)

/// Small helper for assembling graphs in code.
struct RecipeBuilder {
    var graph: RecipeGraph
    private var grid: [UUID: (col: Int, row: Int)] = [:]
    private var pendingFrames: [(title: String, ids: [UUID], color: RGBA)] = []

    init(_ name: String) { graph = RecipeGraph(name: name) }

    /// Adds a node; `col` / `row` place it on a grid (left → right flow). Call `finish()` to pack rows by real node heights.
    @discardableResult
    mutating func add(_ type: String, col: Int, row: Int = 0, _ numbers: [String: Double] = [:], colors: [String: RGBA] = [:],
                      gradient: (String, ColorGradient)? = nil, title: String? = nil, configure: ((inout RecipeNode) -> Void)? = nil) -> UUID {
        var n = RecipeLibrary.makeNode(type, at: CGPoint(x: 40 + col * 240, y: 40 + row * 250))
        for (k, v) in numbers { n.numbers[k] = v }
        for (k, v) in colors { n.colors[k] = v }
        if let g = gradient { n.gradients[g.0] = g.1 }
        n.title = title
        configure?(&n)
        graph.nodes.append(n)
        grid[n.id] = (col, row)
        return n.id
    }

    mutating func wire(_ from: UUID, _ fromPort: String = "Image", _ to: UUID, _ toPort: String = "Image") {
        do { try graph.connect(from: from, fromPort, to: to, toPort) } catch { print("RecipeBuilder: \(graph.name): \(fromPort) → \(toPort): \(error.localizedDescription)") }
    }

    mutating func expose(_ node: UUID, _ key: String, _ label: String) {
        graph.exposed.append(RecipeExposed(node: node, key: key, label: label))
    }

    /// Frames are created by `finish()` (after nodes have their final positions).
    mutating func frame(_ title: String, around ids: [UUID], color: RGBA = RGBA(hex: "4A76B8")!) {
        pendingFrames.append((title, ids, color))
    }

    /// Stacks each column so nodes never overlap, then builds the frames.
    mutating func finish() {
        let rowPitch: CGFloat = 190, gap: CGFloat = 46
        for col in Set(grid.values.map(\.col)) {
            var cursor: CGFloat = 40
            let ids = grid.filter { $0.value.col == col }.sorted { $0.value.row < $1.value.row }.map(\.key)
            for id in ids {
                guard let i = graph.index(id), let g = grid[id] else { continue }
                let y = max(cursor, 40 + CGFloat(g.row) * rowPitch)
                graph.nodes[i].position = CGPoint(x: 40 + CGFloat(col) * 240, y: (y / 10).rounded() * 10)
                cursor = graph.nodes[i].position.y + RecipeLibrary.nodeSize(graph.nodes[i]).height + gap
            }
        }
        for f in pendingFrames {
            let ns = graph.nodes.filter { f.ids.contains($0.id) }
            guard !ns.isEmpty else { continue }
            var r = CGRect.null
            for n in ns { r = r.union(CGRect(origin: n.position, size: RecipeLibrary.nodeSize(n))) }
            graph.frames.append(RecipeFrame(title: f.title, rect: CGRect(x: r.minX - 14, y: r.minY - 34, width: r.width + 28, height: r.height + 48), color: f.color))
        }
        pendingFrames = []
    }
}
