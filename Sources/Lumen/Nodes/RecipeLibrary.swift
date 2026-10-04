import Foundation
import CoreImage
import CoreGraphics
import ImageCratCore

/// Fixed node layout metrics (graph coordinates). Port positions are computed, not measured, so wires never need layout passes.
enum RecipeLayout {
    static let width: CGFloat = 200
    static let header: CGFloat = 24
    static let portRow: CGFloat = 20
    static let paramRow: CGFloat = 22
    static let previewHeight: CGFloat = 104
    static let bottomPad: CGFloat = 6
    /// Parameters beyond this count are inspector-only so nodes stay compact.
    static let maxBodyParams = 8
}

/// The node catalogue.
enum RecipeLibrary {
    static let outputNodeType = "out.output"

    static let all: [RecipeNodeSpec] = inputNodes + generatorNodes + adjustNodes + filterNodes + galleryNodes
        + compositeNodes + transformNodes + mathNodes + utilityNodes + outputNodes

    private static let index: [String: RecipeNodeSpec] = {
        var d: [String: RecipeNodeSpec] = [:]
        for s in all { d[s.type] = s }
        return d
    }()

    static func spec(_ type: String) -> RecipeNodeSpec? { index[type] }

    static func byCategory(_ c: RecipeCategory) -> [RecipeNodeSpec] { all.filter { $0.category == c } }

    /// Groups of a category in first-appearance order ("" first).
    static func groups(_ c: RecipeCategory) -> [String] {
        var g: [String] = []
        for s in byCategory(c) where !g.contains(s.group) { g.append(s.group) }
        return g
    }

    // MARK: Ports

    static func outputIndex(_ node: RecipeNode, _ port: String) -> Int? {
        spec(node.type)?.outputs.firstIndex { $0.name == port }
    }

    static func outputType(_ node: RecipeNode, _ port: String) -> RecipePortType? {
        spec(node.type)?.outputs.first { $0.name == port }?.type
    }

    static func inputType(_ node: RecipeNode, _ port: String) -> RecipePortType? {
        guard let s = spec(node.type) else { return nil }
        if port.hasPrefix("p:") {
            let key = String(port.dropFirst(2))
            return s.param(key)?.portType
        }
        return s.inputs.first { $0.name == port }?.type
    }

    /// Parameters drawn inside the node (the rest are inspector-only).
    static func bodyParams(_ spec: RecipeNodeSpec) -> [RecipeParamSpec] {
        Array(spec.params.filter { !$0.advanced }.prefix(RecipeLayout.maxBodyParams))
    }

    // MARK: Nodes

    /// A node of the given type with default parameter values.
    static func makeNode(_ type: String, at p: CGPoint = .zero) -> RecipeNode {
        var n = RecipeNode(type: type, position: p)
        guard let s = spec(type) else { return n }
        for prm in s.params {
            switch prm.kind {
            case .slider, .int, .angle, .toggle, .choice, .seed: n.numbers[prm.key] = prm.def
            case .color: n.colors[prm.key] = prm.defColor
            case .point: n.vectors[prm.key] = prm.defPoint
            case .gradient: n.gradients[prm.key] = prm.defGradient ?? .twoColor(.black, .white, name: "Black, White")
            case .curve: n.curves[prm.key] = CurvePoints()
            case .text, .file, .layer: if !prm.defString.isEmpty { n.strings[prm.key] = prm.defString }
            }
        }
        if let k = s.adjustmentKind { n.adjustment = AdjustmentSettings(kind: k) }
        return n
    }

    // MARK: Layout

    static func hasPreview(_ node: RecipeNode) -> Bool {
        guard node.showPreview, !node.collapsed, let s = spec(node.type) else { return false }
        return s.outputs.contains { $0.type == .image || $0.type == .mask }
    }

    static func nodeSize(_ node: RecipeNode) -> CGSize {
        guard let s = spec(node.type) else { return CGSize(width: RecipeLayout.width, height: RecipeLayout.header + RecipeLayout.portRow + RecipeLayout.bottomPad) }
        var h = RecipeLayout.header + CGFloat(s.outputs.count) * RecipeLayout.portRow
        if hasPreview(node) { h += RecipeLayout.previewHeight }
        h += CGFloat(s.inputs.count) * RecipeLayout.portRow
        if !node.collapsed { h += CGFloat(bodyParams(s).count) * RecipeLayout.paramRow }
        return CGSize(width: RecipeLayout.width, height: h + RecipeLayout.bottomPad)
    }

    /// Centre of an output socket in graph coordinates.
    static func outputPosition(_ node: RecipeNode, _ port: String) -> CGPoint {
        let i = CGFloat(outputIndex(node, port) ?? 0)
        return CGPoint(x: node.position.x + RecipeLayout.width, y: node.position.y + RecipeLayout.header + (i + 0.5) * RecipeLayout.portRow)
    }

    /// Centre of an input socket (image inputs or "p:<key>" parameter sockets) in graph coordinates.
    static func inputPosition(_ node: RecipeNode, _ port: String) -> CGPoint {
        guard let s = spec(node.type) else { return CGPoint(x: node.position.x, y: node.position.y + RecipeLayout.header / 2) }
        var y = node.position.y + RecipeLayout.header + CGFloat(s.outputs.count) * RecipeLayout.portRow
        if hasPreview(node) { y += RecipeLayout.previewHeight }
        if let i = s.inputs.firstIndex(where: { $0.name == port }) {
            return CGPoint(x: node.position.x, y: y + (CGFloat(i) + 0.5) * RecipeLayout.portRow)
        }
        y += CGFloat(s.inputs.count) * RecipeLayout.portRow
        if port.hasPrefix("p:"), !node.collapsed, let i = bodyParams(s).firstIndex(where: { $0.portName == port }) {
            return CGPoint(x: node.position.x, y: y + (CGFloat(i) + 0.5) * RecipeLayout.paramRow)
        }
        // collapsed / inspector-only parameter: attach to the header
        return CGPoint(x: node.position.x, y: node.position.y + RecipeLayout.header / 2)
    }

    // MARK: Search

    /// Nodes matching a query (name, category, keywords); `accepting` keeps nodes with an input that takes that type,
    /// `producing` keeps nodes with an output convertible to that type.
    static func search(_ query: String, accepting: RecipePortType? = nil, producing: RecipePortType? = nil) -> [RecipeNodeSpec] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let terms = q.split(separator: " ").map(String.init)
        var scored: [(Int, Int, RecipeNodeSpec)] = []
        for (i, s) in all.enumerated() {
            if let t = accepting {
                let ok = s.inputs.contains { t.canConvert(to: $0.type) } || bodyParams(s).contains { p in p.portType.map { t.canConvert(to: $0) } ?? false }
                if !ok { continue }
            }
            if let t = producing, !s.outputs.contains(where: { $0.type.canConvert(to: t) }) { continue }
            if terms.isEmpty { scored.append((0, i, s)); continue }
            let name = s.name.lowercased()
            let hay = name + " " + s.category.rawValue.lowercased() + " " + s.group.lowercased() + " " + s.keywords.joined(separator: " ").lowercased()
            guard terms.allSatisfy({ hay.contains($0) }) else { continue }
            var score = 3
            if name == q { score = 0 } else if name.hasPrefix(q) { score = 1 } else if name.contains(q) { score = 2 }
            scored.append((score, i, s))
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 }
    }
}
