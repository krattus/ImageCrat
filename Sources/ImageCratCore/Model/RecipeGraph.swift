import Foundation

// MARK: - Port types

package enum RecipePortType: String, Codable, CaseIterable {
    case image, mask, number, color, vector, gradient, curve

    package var displayName: String {
        switch self {
        case .image: return "Image"
        case .mask: return "Mask"
        case .number: return "Number"
        case .color: return "Color"
        case .vector: return "Vector"
        case .gradient: return "Gradient"
        case .curve: return "Curve"
        }
    }

    /// Wire / socket colour.
    package var rgba: RGBA {
        switch self {
        case .image: return RGBA(hex: "E8C547")!
        case .mask: return RGBA(hex: "C9CED6")!
        case .number: return RGBA(hex: "6FCF73")!
        case .color: return RGBA(hex: "F2789F")!
        case .vector: return RGBA(hex: "7C8CF8")!
        case .gradient: return RGBA(hex: "3CC9C0")!
        case .curve: return RGBA(hex: "F2994A")!
        }
    }

    /// True when a value of this type can feed an input of type `to` (possibly through an automatic conversion).
    package func canConvert(to: RecipePortType) -> Bool {
        if self == to { return true }
        switch (self, to) {
        case (.number, .color), (.number, .vector), (.number, .image), (.number, .mask): return true
        case (.color, .number), (.color, .image), (.color, .mask), (.color, .gradient): return true
        case (.vector, .number), (.vector, .image): return true
        case (.image, .mask), (.mask, .image): return true
        case (.gradient, .image), (.gradient, .color): return true
        default: return false
        }
    }
}

// MARK: - Graph model

package struct RecipeNode: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var type: String
    package var position: CGPoint = .zero
    package var title: String? = nil
    package var numbers: [String: Double] = [:]
    package var colors: [String: RGBA] = [:]
    package var vectors: [String: CGPoint] = [:]
    package var gradients: [String: ColorGradient] = [:]
    package var curves: [String: CurvePoints] = [:]
    package var strings: [String: String] = [:]
    /// Full settings for "Adjust" nodes.
    package var adjustment: AdjustmentSettings? = nil
    /// Bypass: the node passes its main input through.
    package var muted = false
    package var collapsed = false
    package var showPreview = true

    package init(type: String, position: CGPoint = .zero) {
        self.type = type
        self.position = position
    }

    /// Everything that affects the node's output (ignores layout and labels).
    package func sameValues(as o: RecipeNode) -> Bool {
        type == o.type && muted == o.muted && numbers == o.numbers && colors == o.colors && vectors == o.vectors
            && gradients == o.gradients && curves == o.curves && strings == o.strings && adjustment == o.adjustment
    }
}

extension RecipeNode {
    private enum Keys: String, CodingKey { case id, type, position, title, numbers, colors, vectors, gradients, curves, strings, adjustment, muted, collapsed, showPreview }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(type: (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "unknown")
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        position = (try? c.decodeIfPresent(CGPoint.self, forKey: .position)) ?? .zero
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        numbers = (try? c.decodeIfPresent([String: Double].self, forKey: .numbers)) ?? [:]
        colors = (try? c.decodeIfPresent([String: RGBA].self, forKey: .colors)) ?? [:]
        vectors = (try? c.decodeIfPresent([String: CGPoint].self, forKey: .vectors)) ?? [:]
        gradients = (try? c.decodeIfPresent([String: ColorGradient].self, forKey: .gradients)) ?? [:]
        curves = (try? c.decodeIfPresent([String: CurvePoints].self, forKey: .curves)) ?? [:]
        strings = (try? c.decodeIfPresent([String: String].self, forKey: .strings)) ?? [:]
        adjustment = try? c.decodeIfPresent(AdjustmentSettings.self, forKey: .adjustment)
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        showPreview = (try? c.decodeIfPresent(Bool.self, forKey: .showPreview)) ?? true
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type); try c.encode(position, forKey: .position)
        try c.encodeIfPresent(title, forKey: .title)
        if !numbers.isEmpty { try c.encode(numbers, forKey: .numbers) }
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
        if !vectors.isEmpty { try c.encode(vectors, forKey: .vectors) }
        if !gradients.isEmpty { try c.encode(gradients, forKey: .gradients) }
        if !curves.isEmpty { try c.encode(curves, forKey: .curves) }
        if !strings.isEmpty { try c.encode(strings, forKey: .strings) }
        try c.encodeIfPresent(adjustment, forKey: .adjustment)
        if muted { try c.encode(muted, forKey: .muted) }
        if collapsed { try c.encode(collapsed, forKey: .collapsed) }
        if !showPreview { try c.encode(showPreview, forKey: .showPreview) }
    }
}

/// A wire from an output port to an input port. Parameter inputs use the port name "p:<key>".
package struct RecipeConnection: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var from: UUID
    package var fromPort: String
    package var to: UUID
    package var toPort: String
    package init(id: UUID = UUID(), from: UUID, fromPort: String, to: UUID, toPort: String) {
        self.id = id; self.from = from; self.fromPort = fromPort; self.to = to; self.toPort = toPort
    }
}

extension RecipeConnection {
    private enum Keys: String, CodingKey { case id, from, fromPort, to, toPort }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        from = try c.decode(UUID.self, forKey: .from)
        fromPort = (try? c.decodeIfPresent(String.self, forKey: .fromPort)) ?? "Image"
        to = try c.decode(UUID.self, forKey: .to)
        toPort = (try? c.decodeIfPresent(String.self, forKey: .toPort)) ?? "Image"
    }
}

/// A labelled frame / comment box behind nodes.
package struct RecipeFrame: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var title: String = "Frame"
    package var rect: CGRect
    package var color: RGBA = RGBA(hex: "4A76B8")!
    package var note: String = ""
    package init(id: UUID = UUID(), title: String = "Frame", rect: CGRect, color: RGBA = RGBA(hex: "4A76B8")!, note: String = "") {
        self.id = id; self.title = title; self.rect = rect; self.color = color; self.note = note
    }
}

extension RecipeFrame {
    private enum Keys: String, CodingKey { case id, title, rect, color, note }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Frame"
        rect = (try? c.decodeIfPresent(CGRect.self, forKey: .rect)) ?? CGRect(x: 0, y: 0, width: 300, height: 200)
        color = (try? c.decodeIfPresent(RGBA.self, forKey: .color)) ?? RGBA(hex: "4A76B8")!
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
    }
}

/// A node parameter shown in the Properties panel (the recipe's "custom filter UI").
package struct RecipeExposed: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var node: UUID
    package var key: String
    package var label: String
    package init(id: UUID = UUID(), node: UUID, key: String, label: String) {
        self.id = id; self.node = node; self.key = key; self.label = label
    }
}

extension RecipeExposed {
    private enum Keys: String, CodingKey { case id, node, key, label }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        node = try c.decode(UUID.self, forKey: .node)
        key = try c.decode(String.self, forKey: .key)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? key
    }
}

package enum RecipeGraphError: LocalizedError, Equatable {
    case cycle, incompatible(RecipePortType, RecipePortType), unknownPort, sameNode
    package var errorDescription: String? {
        switch self {
        case .cycle: return "That connection would create a loop."
        case .incompatible(let a, let b): return "\(a.displayName) can't be connected to \(b.displayName)."
        case .unknownPort: return "Unknown port."
        case .sameNode: return "A node can't feed itself."
        }
    }
}

/// A node graph that produces an image. Stored in a Recipe layer (`FillContent.recipe`) or a Recipe smart filter.
package struct RecipeGraph: Codable, Equatable {
    package var version = 1
    package var name = "Recipe"
    package var nodes: [RecipeNode] = []
    package var connections: [RecipeConnection] = []
    package var frames: [RecipeFrame] = []
    package var exposed: [RecipeExposed] = []
    /// "View this node": the canvas shows this node's output instead of the Output node.
    package var solo: UUID? = nil
    /// Pattern origin in document px (moving a Recipe layer shifts generators and coordinates).
    package var origin: CGPoint = .zero

    package init(name: String = "Recipe") { self.name = name }

    // MARK: Lookup

    package func node(_ id: UUID) -> RecipeNode? { nodes.first { $0.id == id } }
    package func index(_ id: UUID) -> Int? { nodes.firstIndex { $0.id == id } }

    package mutating func update(_ id: UUID, _ body: (inout RecipeNode) -> Void) {
        if let i = index(id) { body(&nodes[i]) }
    }

    /// The connection feeding an input port, if any.
    package func input(_ node: UUID, _ port: String) -> RecipeConnection? {
        connections.first { $0.to == node && $0.toPort == port }
    }

    package func outputs(of node: UUID) -> [RecipeConnection] { connections.filter { $0.from == node } }

    // MARK: Editing

    /// True when `target` is reachable downstream from `source` … i.e. wiring source ← target would loop.
    package func dependsOn(_ node: UUID, _ other: UUID) -> Bool {
        if node == other { return true }
        var seen = Set<UUID>(), stack = [node]
        while let n = stack.popLast() {
            if !seen.insert(n).inserted { continue }
            for c in connections where c.to == n {
                if c.from == other { return true }
                stack.append(c.from)
            }
        }
        return false
    }

    package func wouldCreateCycle(from: UUID, to: UUID) -> Bool { dependsOn(from, to) }

    package mutating func disconnect(_ id: UUID) { connections.removeAll { $0.id == id } }

    package mutating func removeNodes(_ ids: Set<UUID>) {
        nodes.removeAll { ids.contains($0.id) }
        connections.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        exposed.removeAll { ids.contains($0.node) }
        if let s = solo, ids.contains(s) { solo = nil }
    }

    /// Drops wires / exposed entries that reference missing nodes or ports (after decoding foreign data).
    package mutating func sanitize() {
        let ids = Set(nodes.map(\.id))
        connections.removeAll { !ids.contains($0.from) || !ids.contains($0.to) || $0.from == $0.to }
        exposed.removeAll { !ids.contains($0.node) }
        if let s = solo, !ids.contains(s) { solo = nil }
        // one wire per input
        var seen = Set<String>()
        connections = connections.reversed().filter { seen.insert("\($0.to)|\($0.toPort)").inserted }.reversed()
        // break cycles (keeps evaluation finite even for hand-edited files)
        var kept: [RecipeConnection] = []
        for c in connections {
            var g = self
            g.connections = kept
            if !g.dependsOn(c.from, c.to) { kept.append(c) }
        }
        connections = kept
    }

    /// Copies of the given nodes (new ids) plus the wires between them.
    package func duplicate(_ ids: Set<UUID>, offset: CGPoint) -> (nodes: [RecipeNode], connections: [RecipeConnection]) {
        var map: [UUID: UUID] = [:]
        var out: [RecipeNode] = []
        for n in nodes where ids.contains(n.id) {
            var c = n
            c.id = UUID()
            c.position = CGPoint(x: n.position.x + offset.x, y: n.position.y + offset.y)
            map[n.id] = c.id
            out.append(c)
        }
        var wires: [RecipeConnection] = []
        for c in connections where ids.contains(c.to) {
            // wires from outside the selection keep their source
            let src = map[c.from] ?? c.from
            wires.append(RecipeConnection(from: src, fromPort: c.fromPort, to: map[c.to]!, toPort: c.toPort))
        }
        return (out, wires)
    }

    package mutating func translate(dx: Double, dy: Double) {
        origin = CGPoint(x: origin.x + CGFloat(dx), y: origin.y + CGFloat(dy))
    }

    /// True when the two graphs render the same (ignores layout, frames, names).
    package func rendersSame(as o: RecipeGraph) -> Bool {
        guard nodes.count == o.nodes.count, connections.count == o.connections.count, solo == o.solo, origin == o.origin else { return false }
        for (a, b) in zip(nodes, o.nodes) where a.id != b.id || !a.sameValues(as: b) { return false }
        for (a, b) in zip(connections, o.connections) where a.from != b.from || a.to != b.to || a.fromPort != b.fromPort || a.toPort != b.toPort { return false }
        return true
    }
}

extension RecipeGraph {
    private enum Keys: String, CodingKey { case version, name, nodes, connections, frames, exposed, solo, origin }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init()
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Recipe"
        nodes = (try? c.decodeIfPresent([RecipeNode].self, forKey: .nodes)) ?? []
        // tolerate individual bad wires
        if let raw = try? c.decodeIfPresent([FailableDecodable<RecipeConnection>].self, forKey: .connections) { connections = raw.compactMap(\.value) }
        frames = (try? c.decodeIfPresent([RecipeFrame].self, forKey: .frames)) ?? []
        if let raw = try? c.decodeIfPresent([FailableDecodable<RecipeExposed>].self, forKey: .exposed) { exposed = raw.compactMap(\.value) }
        solo = try? c.decodeIfPresent(UUID.self, forKey: .solo)
        origin = (try? c.decodeIfPresent(CGPoint.self, forKey: .origin)) ?? .zero
        sanitize()
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version); try c.encode(name, forKey: .name)
        try c.encode(nodes, forKey: .nodes); try c.encode(connections, forKey: .connections)
        if !frames.isEmpty { try c.encode(frames, forKey: .frames) }
        if !exposed.isEmpty { try c.encode(exposed, forKey: .exposed) }
        try c.encodeIfPresent(solo, forKey: .solo)
        if origin != .zero { try c.encode(origin, forKey: .origin) }
    }
}

/// Decodes to nil instead of throwing (lets arrays skip malformed elements).
package struct FailableDecodable<T: Decodable>: Decodable {
    package let value: T?
    package init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
