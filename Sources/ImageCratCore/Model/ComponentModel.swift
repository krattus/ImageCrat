import Foundation

// MARK: - Components (Figma-style main components + instances with overrides)
//
// Storage / render design
// ───────────────────────
// • The MAIN component lives in `DocumentState.components` (a table keyed by component id). Its content is a layer
//   tree in its own coordinate space (like a smart object's embedded document), plus optional named variants.
// • An INSTANCE is an ordinary smart-object layer whose `SmartObjectContent.component` is set. That small record holds
//   the component id, the chosen variant and the override table. The smart object's `source` is a *materialised cache*:
//   the master tree with the overrides applied (`ComponentEngine.resolve`). Pixel buffers are shared by reference, so
//   an instance costs a few hundred bytes in memory, and on disk the cache is stripped (`ComponentCodec`) and rebuilt
//   from the table when the document is decoded.
// • Because an instance IS a smart object, everything that works on smart objects keeps working unchanged: the
//   compositor, free transform / warp / perspective (the quad), smart filters, masks, layer styles, duplicate, group,
//   PSD export (rasterised like any smart object), undo/redo (the table is part of the undoable state).
// • Editing the main component re-resolves every instance (`ComponentEngine.refresh`), bumping `sourceRevision`.

/// A named variation of a component (e.g. Hover / Disabled / Dark). Inner layer ids are shared with the default
/// tree where the layers correspond, so overrides keep applying when an instance switches variant.
package struct ComponentVariant: Codable, Identifiable {
    package var id = UUID()
    package var name: String
    package var width: Int
    package var height: Int
    package var layers: [Layer]

    package init(name: String, width: Int, height: Int, layers: [Layer]) {
        self.name = name; self.width = width; self.height = height; self.layers = layers
    }

    private enum K: String, CodingKey { case id, name, width, height, layers }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Variant"
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? 1
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? 1
        layers = (try? c.decodeIfPresent([Layer].self, forKey: .layers)) ?? []
    }
}

/// Where a document's copy of a component came from (cross-document library).
package struct ComponentLibraryLink: Codable, Equatable {
    package var libraryID: UUID
    package var libraryName: String
    package var version: Int
    package init(libraryID: UUID, libraryName: String, version: Int) {
        self.libraryID = libraryID; self.libraryName = libraryName; self.version = version
    }
}

/// The main component stored in the document's component table.
package struct ComponentMaster: Codable, Identifiable {
    package var id = UUID()
    package var name: String
    package var width: Int
    package var height: Int
    /// Default variant tree (bottom-first), in the component's own coordinate space.
    package var layers: [Layer]
    package var defaultVariantName = "Default"
    package var variants: [ComponentVariant] = []
    /// Bumped on every change of the main component (library "newer version" checks, thumbnails).
    package var version = 1
    package var created = Date()
    package var modified = Date()
    package var library: ComponentLibraryLink? = nil

    package init(name: String, width: Int, height: Int, layers: [Layer]) {
        self.name = name; self.width = max(1, width); self.height = max(1, height); self.layers = layers
    }

    private enum K: String, CodingKey { case id, name, width, height, layers, defaultVariantName, variants, version, created, modified, library }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Component"
        width = max(1, (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? 1)
        height = max(1, (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? 1)
        layers = (try? c.decodeIfPresent([Layer].self, forKey: .layers)) ?? []
        defaultVariantName = (try? c.decodeIfPresent(String.self, forKey: .defaultVariantName)) ?? "Default"
        variants = (try? c.decodeIfPresent([ComponentVariant].self, forKey: .variants)) ?? []
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
        modified = (try? c.decodeIfPresent(Date.self, forKey: .modified)) ?? Date()
        library = try? c.decodeIfPresent(ComponentLibraryLink.self, forKey: .library)
    }

    /// (name, id) of every variant, default first (`nil` id).
    package var variantChoices: [(name: String, id: UUID?)] { [(defaultVariantName, nil)] + variants.map { ($0.name, Optional($0.id)) } }

    package func variantName(_ id: UUID?) -> String {
        guard let id else { return defaultVariantName }
        return variants.first { $0.id == id }?.name ?? defaultVariantName
    }

    /// Layer tree and canvas size of a variant (falls back to the default tree when the variant no longer exists).
    package func tree(_ variant: UUID?) -> (layers: [Layer], width: Int, height: Int) {
        if let v = variant, let x = variants.first(where: { $0.id == v }) { return (x.layers, max(1, x.width), max(1, x.height)) }
        return (layers, width, height)
    }

    package mutating func setTree(_ variant: UUID?, layers l: [Layer], width w: Int, height h: Int) {
        if let v = variant, let i = variants.firstIndex(where: { $0.id == v }) {
            variants[i].layers = l; variants[i].width = max(1, w); variants[i].height = max(1, h)
        } else {
            layers = l; width = max(1, w); height = max(1, h)
        }
    }

    package mutating func touch() { version += 1; modified = Date() }
}

package enum ComponentOverrideKind: String, Codable, CaseIterable {
    case text, image, fill, stroke, visible

    package var label: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        case .fill: return "Fill"
        case .stroke: return "Stroke"
        case .visible: return "Visibility"
        }
    }
}

/// One entry of an instance's override table: targets an inner layer of the main component by its stable id
/// (the name is kept so overrides survive "Swap Component" when a layer of the same name exists).
package struct ComponentOverride: Codable, Identifiable {
    package var id = UUID()
    package var layerID: UUID
    package var layerName: String
    package var kind: ComponentOverrideKind
    package var text: String? = nil
    package var color: RGBA? = nil
    package var image: PixelBuffer? = nil
    package var imageName: String? = nil
    package var visible: Bool? = nil

    package init(layerID: UUID, layerName: String, kind: ComponentOverrideKind) {
        self.layerID = layerID; self.layerName = layerName; self.kind = kind
    }

    /// Short human-readable value for the Overrides list.
    package var summary: String {
        switch kind {
        case .text: return "“\((text ?? "").replacingOccurrences(of: "\n", with: " ").prefix(28))”"
        case .image: return imageName ?? (image.map { "\($0.width)×\($0.height) px" } ?? "image")
        case .fill, .stroke: return "#" + (color?.hex ?? "000000")
        case .visible: return (visible ?? true) ? "shown" : "hidden"
        }
    }
}

/// Whole-instance tint (a colour overlay over the resolved component).
package struct ComponentTint: Codable, Equatable {
    package var color: RGBA
    /// 0…1 strength.
    package var amount: Double = 1
    package var blendMode: BlendMode = .normal

    package init(color: RGBA, amount: Double = 1, blendMode: BlendMode = .normal) { self.color = color; self.amount = amount; self.blendMode = blendMode }
    private enum K: String, CodingKey { case color, amount, blendMode }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        color = (try? c.decodeIfPresent(RGBA.self, forKey: .color)) ?? .black
        amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? 1
        blendMode = (try? c.decodeIfPresent(BlendMode.self, forKey: .blendMode)) ?? .normal
    }
}

/// The lightweight part of an instance layer (`SmartObjectContent.component`).
package struct ComponentInstance: Codable {
    package var componentID: UUID
    /// nil = default variant.
    package var variantID: UUID? = nil
    package var overrides: [ComponentOverride] = []
    package var tint: ComponentTint? = nil
    /// Size of the resolved source the quad corresponds to (nil until first resolved).
    package var sourceSize: CGSize? = nil

    package init(componentID: UUID, variantID: UUID? = nil) { self.componentID = componentID; self.variantID = variantID }

    private enum K: String, CodingKey { case componentID, variantID, overrides, tint, sourceSize }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        componentID = try c.decode(UUID.self, forKey: .componentID)
        variantID = try? c.decodeIfPresent(UUID.self, forKey: .variantID)
        // One malformed override must not lose the others.
        if var arr = try? c.nestedUnkeyedContainer(forKey: .overrides) {
            var out: [ComponentOverride] = []
            while !arr.isAtEnd {
                if let o = try? arr.decode(ComponentOverride.self) { out.append(o) } else if (try? arr.decode(ComponentSkip.self)) == nil { break }
            }
            overrides = out
        }
        tint = try? c.decodeIfPresent(ComponentTint.self, forKey: .tint)
        sourceSize = try? c.decodeIfPresent(CGSize.self, forKey: .sourceSize)
    }

    package var hasOverrides: Bool { !overrides.isEmpty || tint != nil }
    package var overrideCount: Int { overrides.count + (tint == nil ? 0 : 1) }

    package func override(_ layer: UUID, _ kind: ComponentOverrideKind) -> ComponentOverride? {
        overrides.first { $0.layerID == layer && $0.kind == kind }
    }

    package mutating func set(_ o: ComponentOverride) {
        if let i = overrides.firstIndex(where: { $0.layerID == o.layerID && $0.kind == o.kind }) {
            var n = o; n.id = overrides[i].id
            overrides[i] = n
        } else {
            overrides.append(o)
        }
    }

    package mutating func remove(_ layer: UUID, _ kind: ComponentOverrideKind) {
        overrides.removeAll { $0.layerID == layer && $0.kind == kind }
    }
}

/// Decodes (and discards) any value, so a lossy array decode can step over an element it does not understand.
private struct ComponentSkip: Decodable { init(from decoder: Decoder) throws {} }

extension Layer {
    /// The instance record when this layer is a component instance.
    package var componentInstance: ComponentInstance? { smart?.component }
    package var isComponentInstance: Bool { smart?.component != nil }
}

// MARK: - On-disk form

/// Instances are stored without their materialised source (it is rebuilt from the component table on load), which
/// keeps documents small: fifty instances of a component store the component once.
package enum ComponentCodec {
    package static let placeholder = PixelBuffer(width: 1, height: 1)

    /// Layers with the resolved source of every resolvable instance replaced by a 1×1 placeholder.
    package static func stripped(_ layers: [Layer], _ table: [UUID: ComponentMaster]) -> [Layer] {
        guard !table.isEmpty, containsInstance(layers) else { return layers }
        return layers.map { l in
            var l = l
            switch l.content {
            case .smartObject(var so):
                if let inst = so.component, table[inst.componentID] != nil {
                    so.source = .image(placeholder)
                    l.content = .smartObject(so)
                }
            case .group(var g):
                g.children = stripped(g.children, table)
                l.content = .group(g)
            default: break
            }
            return l
        }
    }

    package static func containsInstance(_ layers: [Layer]) -> Bool {
        for l in layers {
            if l.isComponentInstance { return true }
            if case .group(let g) = l.content, containsInstance(g.children) { return true }
        }
        return false
    }

    /// Rebuilds component instances from the table. Installed by the platform layer (`ComponentEngine.refresh`:
    /// image overrides are scaled and masked with the platform's drawing code); nil leaves instances as decoded.
    nonisolated(unsafe) package static var refreshInstances: ((inout DocumentState) -> Void)?

    /// After decoding: rebuild every instance whose component is in the table.
    package static func restore(_ st: inout DocumentState) {
        guard !st.components.isEmpty else { return }
        refreshInstances?(&st)
    }
}
