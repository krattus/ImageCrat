import Foundation
import CoreGraphics
import CoreImage
import ImageCratCore

/// Pure (UI-free) component logic: resolving instances, overrides, variants, detach, swap, cross-document adoption.
enum ComponentEngine {
    // MARK: Revisions

    /// Smart-object render caches compare `sourceRevision`; a process-wide counter guarantees a revision is never
    /// reused for different content (undo → different edit would otherwise collide).
    private static var counter = (Int(Date().timeIntervalSince1970) % 1_000_000) * 1000
    static func nextRevision() -> Int { counter += 1; return counter }

    // MARK: Resolve

    /// The master tree of `inst` with nested instances refreshed, overrides applied and the tint added.
    static func resolve(_ inst: ComponentInstance, table: [UUID: ComponentMaster], visiting: Set<UUID> = []) -> DocumentState? {
        guard let m = table[inst.componentID], !visiting.contains(inst.componentID), visiting.count < 8 else { return nil }
        let tree = m.tree(inst.variantID)
        var layers = tree.layers
        if ComponentCodec.containsInstance(layers) {
            _ = refresh(&layers, table: table, only: nil, visiting: visiting.union([inst.componentID]))
        }
        for o in inst.overrides { _ = apply(o, to: &layers) }
        if let t = inst.tint, t.amount > 0.001 {
            var g = Layer(name: "Tint", content: .group(GroupContent(children: layers, isExpanded: false)))
            g.id = tintLayerID(inst.componentID)
            g.blendMode = .normal
            g.effects.colorOverlay = ColorOverlayEffect(enabled: true, blendMode: t.blendMode, color: t.color.withAlpha(1), opacity: clamp(t.amount, 0, 1))
            layers = [g]
        }
        var st = DocumentState(width: tree.width, height: tree.height)
        st.layers = layers
        return st
    }

    /// Stable id for the tint wrapper (derived from the component id, so render caches do not grow per resolve).
    static func tintLayerID(_ component: UUID) -> UUID {
        var u = component.uuid
        u.0 ^= 0x7A; u.1 ^= 0x11; u.15 ^= 0xC3
        return UUID(uuid: u)
    }

    /// The master tree with nested instances brought up to date (thumbnails, Edit Main Component).
    static func freshTree(_ m: ComponentMaster, variant: UUID?, table: [UUID: ComponentMaster]) -> (layers: [Layer], width: Int, height: Int) {
        var t = m.tree(variant)
        if ComponentCodec.containsInstance(t.layers) { _ = refresh(&t.layers, table: table, only: nil, visiting: [m.id]) }
        return t
    }

    /// Re-resolves instances in a layer tree (groups and the embedded documents of plain smart objects included).
    /// `only` limits the work to instances of those components. Returns the number of instances rebuilt.
    @discardableResult
    static func refresh(_ layers: inout [Layer], table: [UUID: ComponentMaster], only: Set<UUID>?, visiting: Set<UUID> = []) -> Int {
        var n = 0
        for i in layers.indices {
            switch layers[i].content {
            case .smartObject(var so):
                if var inst = so.component {
                    if let o = only, !o.contains(inst.componentID) { continue }
                    guard let st = resolve(inst, table: table, visiting: visiting) else { continue }
                    let size = CGSize(width: st.width, height: st.height)
                    if let old = inst.sourceSize, old != size, old.width > 0, old.height > 0 {
                        // Same placement, adapted to the new master size (like Edit Contents does).
                        let sx = size.width / old.width, sy = size.height / old.height
                        let tl = so.quad.tl
                        let U = so.quad.tr - so.quad.tl, V = so.quad.bl - so.quad.tl
                        so.quad = Quad(tl: tl, tr: tl + U * sx, br: tl + U * sx + V * sy, bl: tl + V * sy)
                    }
                    inst.sourceSize = size
                    so.component = inst
                    so.source = .document(st)
                    so.sourceRevision = nextRevision()
                    if let m = table[inst.componentID] { so.sourceName = m.name }
                    layers[i].content = .smartObject(so)
                    n += 1
                } else if case .document(var inner) = so.source, ComponentCodec.containsInstance(inner.layers) {
                    let t = inner.components.isEmpty ? table : table.merging(inner.components) { _, own in own }
                    let c = refresh(&inner.layers, table: t, only: only, visiting: visiting)
                    if c > 0 {
                        so.source = .document(inner)
                        so.sourceRevision = nextRevision()
                        layers[i].content = .smartObject(so)
                        n += c
                    }
                }
            case .group(var g):
                let c = refresh(&g.children, table: table, only: only, visiting: visiting)
                if c > 0 { layers[i].content = .group(g); n += c }
            default: break
            }
        }
        return n
    }

    /// Rebuilds every instance affected by a change to `changed` (nil = all), including instances of components
    /// that nest a changed component.
    @discardableResult
    static func refresh(_ st: inout DocumentState, changed: Set<UUID>? = nil) -> Int {
        let only = changed.map { dependents(of: $0, table: st.components) }
        return refresh(&st.layers, table: st.components, only: only)
    }

    // MARK: Queries

    /// Component ids used by instances in a tree (groups, variants of nothing — just the layers given — and plain
    /// smart-object documents included).
    static func usedComponentIDs(_ layers: [Layer]) -> Set<UUID> {
        var s = Set<UUID>()
        for l in layers {
            switch l.content {
            case .smartObject(let so):
                if let c = so.component { s.insert(c.componentID) }
                else if case .document(let inner) = so.source { s.formUnion(usedComponentIDs(inner.layers)) }
            case .group(let g): s.formUnion(usedComponentIDs(g.children))
            default: break
            }
        }
        return s
    }

    static func usedComponentIDs(_ m: ComponentMaster) -> Set<UUID> {
        var s = usedComponentIDs(m.layers)
        for v in m.variants { s.formUnion(usedComponentIDs(v.layers)) }
        return s
    }

    /// `ids` plus every component that (transitively) contains an instance of one of them.
    static func dependents(of ids: Set<UUID>, table: [UUID: ComponentMaster]) -> Set<UUID> {
        var s = ids
        var changed = true
        while changed {
            changed = false
            for (id, m) in table where !s.contains(id) {
                if !usedComponentIDs(m).isDisjoint(with: s) { s.insert(id); changed = true }
            }
        }
        return s
    }

    /// `ids` plus every component they (transitively) nest.
    static func dependencies(of ids: Set<UUID>, table: [UUID: ComponentMaster]) -> Set<UUID> {
        var s = ids
        var queue = Array(ids)
        while let id = queue.popLast() {
            guard let m = table[id] else { continue }
            for u in usedComponentIDs(m) where !s.contains(u) { s.insert(u); queue.append(u) }
        }
        return s
    }

    /// Instance layers of a component in a document (top-level tree only; bottom-first).
    static func instances(of component: UUID?, in st: DocumentState) -> [Layer] {
        st.allLayers.filter { l in
            guard let c = l.componentInstance else { return false }
            return component == nil || c.componentID == component
        }
    }

    static func usageCount(_ component: UUID, in st: DocumentState) -> Int { instances(of: component, in: st).count }

    /// Components sorted for display (creation order, then name).
    static func sorted(_ table: [UUID: ComponentMaster]) -> [ComponentMaster] {
        table.values.sorted { a, b in a.created != b.created ? a.created < b.created : a.name < b.name }
    }

    // MARK: Overrides

    /// Override kinds an inner layer supports.
    static func overridableKinds(_ l: Layer) -> [ComponentOverrideKind] {
        switch l.content {
        case .text: return [.text, .fill, .visible]
        case .shape(let s):
            var k: [ComponentOverrideKind] = [.fill]
            if !s.stroke.paint.isNone && s.stroke.width > 0 { k.append(.stroke) }
            return k + [.visible]
        case .raster: return [.image, .visible]
        case .smartObject(let so): return so.component == nil ? [.image, .visible] : [.visible]
        case .fill: return [.fill, .visible]
        case .group: return l.vectorMask != nil ? [.image, .visible] : [.visible]
        case .adjustment: return [.visible]
        }
    }

    /// Inner layers of a tree in panel order (top first) with their depth.
    static func overridableLayers(_ layers: [Layer]) -> [(layer: Layer, depth: Int)] {
        layers.flattenedForDisplay(includeCollapsed: true).map { ($0.0, $0.1) }
    }

    /// The master's value for an override slot (what "reset" goes back to), as a display string.
    static func masterValue(_ l: Layer, _ kind: ComponentOverrideKind) -> String {
        switch kind {
        case .text: return l.text?.text ?? ""
        case .fill:
            if let t = l.text { return "#" + t.color.hex }
            if let s = l.shape, let c = s.fill.solidColor { return "#" + c.hex }
            if let f = l.fill, let c = f.paint.solidColor { return "#" + c.hex }
            return "—"
        case .stroke: return l.shape?.stroke.paint.solidColor.map { "#" + $0.hex } ?? "—"
        case .visible: return l.isVisible ? "shown" : "hidden"
        case .image: return "original"
        }
    }

    /// Current colour of an overridable slot in the master (seed for the colour well).
    static func masterColor(_ l: Layer, _ kind: ComponentOverrideKind) -> RGBA {
        switch kind {
        case .stroke: return l.shape?.stroke.paint.solidColor ?? .black
        default:
            if let t = l.text { return t.color }
            if let s = l.shape { return s.fill.solidColor ?? RGBA(hex: "4A90E2")! }
            if let f = l.fill { return f.paint.solidColor ?? .black }
            return .black
        }
    }

    /// Applies one override to a (copy of a) master tree. Returns false when the target layer no longer exists.
    @discardableResult
    static func apply(_ o: ComponentOverride, to layers: inout [Layer]) -> Bool {
        layers.update(o.layerID) { l in
            switch o.kind {
            case .visible:
                l.isVisible = o.visible ?? true
            case .text:
                if var t = l.text {
                    t.text = o.text ?? ""
                    t.normalizeRuns()
                    l.text = t
                }
            case .fill:
                guard let c = o.color else { return }
                switch l.content {
                case .text(var t):
                    t.applyLayerWide(CharacterStyle(color: c))
                    l.content = .text(t)
                case .shape(var s):
                    s.fill = .color(c)
                    l.content = .shape(s)
                case .fill:
                    l.content = .fill(FillContent(paint: .color(c)))
                default:
                    // pixels / groups: recolour through a colour overlay (icons, glyph rasters)
                    l.effects.enabled = true
                    l.effects.colorOverlay = ColorOverlayEffect(enabled: true, blendMode: .normal, color: c.withAlpha(1), opacity: c.a)
                }
            case .stroke:
                guard let c = o.color else { return }
                if var s = l.shape {
                    s.stroke.paint = .color(c)
                    if s.stroke.width <= 0 { s.stroke.width = 1 }
                    l.shape = s
                } else if l.effects.stroke.enabled {
                    l.effects.stroke.paint = .color(c)
                }
            case .image:
                guard let img = o.image else { return }
                applyImage(img, to: &l, overrideID: o.id)
            }
        }
    }

    private static func applyImage(_ img: PixelBuffer, to l: inout Layer, overrideID: UUID) {
        switch l.content {
        case .raster(let r):
            // Keep the placeholder's silhouette (e.g. a round avatar): the new image is drawn "source in".
            let ob = r.buffer.opaqueBounds() ?? r.buffer.bounds
            let out = ImageFit.masked(img, shape: r.buffer, bounds: ob)
            l.content = .raster(RasterContent(buffer: out, origin: IPoint(x: r.origin.x + ob.x, y: r.origin.y + ob.y)))
        case .smartObject(var so):
            guard so.component == nil else { return }
            let sz = so.source.size
            so.source = .image(ImageFit.cropped(img, aspect: sz.width / max(1, sz.height)))
            so.linkedURL = nil
            so.linkedModified = nil
            l.content = .smartObject(so)
        case .group(var g):
            // Frame (group + vector mask): the image fills the frame.
            guard let fr = l.vectorMask?.bounds, fr.width > 0, fr.height > 0 else { return }
            let fitted = ImageFit.cropped(img, aspect: fr.width / fr.height)
            if let i = g.children.firstIndex(where: { $0.isSmartObject && !$0.isComponentInstance }), var so = g.children[i].smart {
                so.source = .image(fitted); so.quad = Quad(rect: fr); so.warp = nil; so.linkedURL = nil
                g.children[i].content = .smartObject(so)
            } else {
                var child = Layer(name: "Image", content: .smartObject(SmartObjectContent(source: .image(fitted), quad: Quad(rect: fr), sourceName: "Image")))
                child.id = overrideID
                g.children.append(child)
            }
            l.content = .group(g)
        default: break
        }
    }

    // MARK: Creating components and instances

    /// Builds a main component from document layers (bottom-first). Returns the master and the doc rect it occupied.
    static func makeMaster(from layers: [Layer], state: DocumentState, name: String) -> (ComponentMaster, IRect)? {
        guard !layers.isEmpty else { return nil }
        var u: CGRect? = nil
        for l in layers { if let b = Compositor.shared.contentBounds(l, state: state) { u = u.map { $0.union(b) } ?? b } }
        guard let b0 = u, b0.width > 0, b0.height > 0 else { return nil }
        let maxFx = layers.map { maxEffectExtent($0) }.max() ?? 0
        let b = IRect(enclosing: b0.insetBy(dx: -CGFloat(maxFx), dy: -CGFloat(maxFx)))
        var inner: [Layer] = []
        for (i, src) in layers.enumerated() {
            var l = src
            l.translate(dx: Double(-b.x), dy: Double(-b.y), document: true)
            if i == 0 { l.isClipped = false }
            l.linkID = nil
            inner.append(l)
        }
        return (ComponentMaster(name: name, width: b.width, height: b.height, layers: inner), b)
    }

    private static func maxEffectExtent(_ l: Layer) -> Double {
        var e = l.effects.enabled && l.effects.hasAny ? l.effects.extent : 0
        for c in l.children { e = max(e, maxEffectExtent(c)) }
        return e
    }

    /// A new instance layer of a component. `rect` defaults to the component's natural size at the origin.
    static func instanceLayer(of id: UUID, variant: UUID? = nil, table: [UUID: ComponentMaster], rect: CGRect? = nil, name: String? = nil) -> Layer? {
        guard let m = table[id] else { return nil }
        var inst = ComponentInstance(componentID: id, variantID: variant)
        guard let st = resolve(inst, table: table) else { return nil }
        inst.sourceSize = CGSize(width: st.width, height: st.height)
        var so = SmartObjectContent(source: .document(st), quad: Quad(rect: rect ?? CGRect(x: 0, y: 0, width: st.width, height: st.height)), sourceName: m.name)
        so.sourceRevision = nextRevision()
        so.component = inst
        return Layer(name: name ?? m.name, content: .smartObject(so))
    }

    /// Unique component name within a table ("Button", "Button 2", …).
    static func uniqueName(_ base: String, in table: [UUID: ComponentMaster]) -> String {
        let names = Set(table.values.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: Instance operations (value level)

    /// Mutates the instance record of a layer and rebuilds its source.
    @discardableResult
    static func updateInstance(_ id: UUID, in st: inout DocumentState, _ body: (inout ComponentInstance) -> Void) -> Bool {
        let table = st.components
        var ok = false
        st.updateLayer(id) { l in
            guard var so = l.smart, var inst = so.component else { return }
            body(&inst)
            so.component = inst
            var one = [Layer(name: l.name, content: .smartObject(so))]
            if refresh(&one, table: table, only: nil) > 0, let r = one[0].smart { so = r }
            l.smart = so
            ok = true
        }
        return ok
    }

    /// Bakes an instance's overrides into the main component (the variant the instance uses) and clears them.
    /// All instances are rebuilt. The tint stays on the instance (it is per-instance by nature).
    @discardableResult
    static func pushOverrides(_ id: UUID, in st: inout DocumentState) -> Bool {
        guard let inst = st.layer(id)?.componentInstance, var m = st.components[inst.componentID], !inst.overrides.isEmpty else { return false }
        var tree = m.tree(inst.variantID)
        for o in inst.overrides { _ = apply(o, to: &tree.layers) }
        m.setTree(inst.variantID, layers: tree.layers, width: tree.width, height: tree.height)
        m.touch()
        st.components[m.id] = m
        st.updateLayer(id) { l in l.smart?.component?.overrides = [] }
        refresh(&st, changed: [m.id])
        return true
    }

    /// Instance → ordinary layers (a group holding the resolved tree, mapped through the instance's quad).
    static func detached(_ layer: Layer, space: CanvasSpace) -> Layer? {
        guard let so = layer.smart, so.component != nil, case .document(let st) = so.source else { return nil }
        let from = Quad(rect: CGRect(x: 0, y: 0, width: st.width, height: st.height))
        guard let h = Homography(from: from, to: so.quad) else { return nil }
        let sc = (Double(so.quad.tl.distance(to: so.quad.tr)) / Double(max(1, st.width)) + Double(so.quad.tl.distance(to: so.quad.bl)) / Double(max(1, st.height))) / 2
        let k: Double? = abs(sc - 1) > 0.01 ? sc : nil
        let children = st.layers.map { LayerTransformer.apply(h, to: reidentified($0), space: space, scaleEffects: k) }
        var g = Layer(name: layer.name, content: .group(GroupContent(children: children, isExpanded: false)))
        g.id = layer.id
        g.isVisible = layer.isVisible; g.opacity = layer.opacity; g.fillOpacity = layer.fillOpacity
        g.blendMode = layer.blendMode == .passThrough ? .normal : layer.blendMode
        g.isClipped = layer.isClipped; g.locks = layer.locks; g.mask = layer.mask
        g.vectorMask = layer.vectorMask; g.vectorMaskEnabled = layer.vectorMaskEnabled
        g.effects = layer.effects; g.colorLabel = layer.colorLabel; g.linkID = layer.linkID
        g.blendIf = layer.blendIf
        return g
    }

    /// New ids for a subtree (pixel buffers stay shared: states treat them as immutable).
    static func reidentified(_ l: Layer) -> Layer {
        var n = l
        n.id = UUID()
        if case .group(var g) = n.content { g.children = g.children.map(reidentified); n.content = .group(g) }
        return n
    }

    /// The instance record after swapping to another component: overrides that still match (same inner id, or an
    /// inner layer of the same name supporting that kind) are kept, the rest dropped. The variant is matched by name.
    static func swapped(_ inst: ComponentInstance, to newID: UUID, table: [UUID: ComponentMaster]) -> ComponentInstance {
        guard let nm = table[newID] else { return inst }
        var out = ComponentInstance(componentID: newID)
        out.tint = inst.tint
        out.sourceSize = inst.sourceSize
        if let old = table[inst.componentID], inst.variantID != nil {
            let name = old.variantName(inst.variantID)
            out.variantID = nm.variants.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        let targets = nm.tree(out.variantID).layers.allLayers
        for o in inst.overrides {
            if let t = targets.first(where: { $0.id == o.layerID }), overridableKinds(t).contains(o.kind) {
                out.overrides.append(o)
            } else if let t = targets.first(where: { $0.name == o.layerName && overridableKinds($0).contains(o.kind) }) {
                var n = o
                n.layerID = t.id
                if !out.overrides.contains(where: { $0.layerID == n.layerID && $0.kind == n.kind }) { out.overrides.append(n) }
            }
        }
        return out
    }

    /// Swaps the component of an instance layer, keeping its centre and scale.
    @discardableResult
    static func swap(_ id: UUID, to newID: UUID, in st: inout DocumentState) -> Bool {
        guard let l = st.layer(id), let so = l.smart, let inst = so.component, st.components[newID] != nil else { return false }
        let table = st.components
        let next = swapped(inst, to: newID, table: table)
        guard let resolved = resolve(next, table: table) else { return false }
        let oldSize = inst.sourceSize ?? so.source.size
        let newSize = CGSize(width: resolved.width, height: resolved.height)
        st.updateLayer(id) { l in
            guard var s = l.smart else { return }
            // keep centre, rotation and the per-axis scale
            let c = s.quad.center
            let U = (s.quad.tr - s.quad.tl) / max(1, oldSize.width), V = (s.quad.bl - s.quad.tl) / max(1, oldSize.height)
            let hw = U * (newSize.width / 2), hh = V * (newSize.height / 2)
            s.quad = Quad(tl: c - hw - hh, tr: c + hw - hh, br: c + hw + hh, bl: c - hw + hh)
            s.warp = nil
            var n = next
            n.sourceSize = newSize
            s.component = n
            s.source = .document(resolved)
            s.sourceRevision = nextRevision()
            if let m = table[newID] {
                if l.name == s.sourceName { l.name = m.name }
                s.sourceName = m.name
            }
            l.smart = s
        }
        return true
    }

    // MARK: Variants

    /// Adds a variant copied from another variant's tree (ids preserved so overrides carry across).
    @discardableResult
    static func addVariant(_ name: String, to component: UUID, basedOn: UUID? = nil, layers: [Layer]? = nil, in st: inout DocumentState) -> UUID? {
        guard var m = st.components[component] else { return nil }
        let base = m.tree(basedOn)
        let v = ComponentVariant(name: uniqueVariantName(name, m), width: base.width, height: base.height, layers: layers ?? base.layers)
        m.variants.append(v)
        m.touch()
        st.components[component] = m
        return v.id
    }

    static func uniqueVariantName(_ base: String, _ m: ComponentMaster) -> String {
        let names = Set(m.variantChoices.map(\.name))
        let b = base.isEmpty ? "Variant" : base
        if !names.contains(b) { return b }
        var i = 2
        while names.contains("\(b) \(i)") { i += 1 }
        return "\(b) \(i)"
    }

    /// Removes a variant; instances using it fall back to the default.
    static func deleteVariant(_ variant: UUID, of component: UUID, in st: inout DocumentState) {
        guard var m = st.components[component] else { return }
        m.variants.removeAll { $0.id == variant }
        m.touch()
        st.components[component] = m
        mapInstances(&st.layers) { inst in
            if inst.componentID == component && inst.variantID == variant { inst.variantID = nil }
        }
        refresh(&st, changed: [component])
    }

    /// Applies `body` to every instance record in a tree (no re-resolve).
    static func mapInstances(_ layers: inout [Layer], _ body: (inout ComponentInstance) -> Void) {
        for i in layers.indices {
            switch layers[i].content {
            case .smartObject(var so):
                if var inst = so.component { body(&inst); so.component = inst; layers[i].content = .smartObject(so) }
            case .group(var g):
                mapInstances(&g.children, body)
                layers[i].content = .group(g)
            default: break
            }
        }
    }

    // MARK: Table maintenance

    /// Removes a component. Its instances become ordinary smart objects (they keep their current look).
    static func deleteComponent(_ id: UUID, in st: inout DocumentState) {
        st.components[id] = nil
        func strip(_ layers: inout [Layer]) {
            for i in layers.indices {
                switch layers[i].content {
                case .smartObject(var so):
                    if so.component?.componentID == id { so.component = nil; layers[i].content = .smartObject(so) }
                case .group(var g): strip(&g.children); layers[i].content = .group(g)
                default: break
                }
            }
        }
        strip(&st.layers)
        for k in Array(st.components.keys) {
            guard var m = st.components[k], usedComponentIDs(m).contains(id) else { continue }
            strip(&m.layers)
            for i in m.variants.indices { strip(&m.variants[i].layers) }
            st.components[k] = m
        }
    }

    /// A copy of a component under a new id and name (inner layer ids are kept, so swapping between the copy and the
    /// original keeps every override).
    @discardableResult
    static func duplicateComponent(_ id: UUID, in st: inout DocumentState) -> UUID? {
        guard var m = st.components[id] else { return nil }
        m.id = UUID()
        m.name = uniqueName(m.name + " copy", in: st.components)
        m.created = Date(); m.modified = Date(); m.version = 1
        m.library = nil
        m.variants = m.variants.map { var v = $0; v.id = UUID(); return v }
        st.components[m.id] = m
        return m.id
    }

    /// Copies the masters of instances whose component is missing from this document's table (paste / drag from
    /// another document) from `source`, including nested dependencies. Returns the ids added.
    @discardableResult
    static func adoptMissing(_ st: inout DocumentState, lookup: (UUID) -> ComponentMaster?) -> [UUID] {
        var missing = usedComponentIDs(st.layers).subtracting(st.components.keys)
        guard !missing.isEmpty else { return [] }
        var added: [UUID] = []
        var guardCount = 0
        while let id = missing.popFirst(), guardCount < 500 {
            guardCount += 1
            guard st.components[id] == nil, let m = lookup(id) else { continue }
            st.components[id] = m
            added.append(id)
            for d in usedComponentIDs(m) where st.components[d] == nil { missing.insert(d) }
        }
        return added
    }

    /// True when `tree` (transitively) contains an instance of `component` — it must not be stored as that
    /// component's own content.
    static func wouldCycle(_ tree: [Layer], component: UUID, table: [UUID: ComponentMaster]) -> Bool {
        let used = usedComponentIDs(tree)
        if used.contains(component) { return true }
        return dependencies(of: used, table: table).contains(component)
    }

    /// Turns instances of `component` inside a tree into plain smart objects (breaks a would-be cycle).
    static func unlinkInstances(of component: UUID, in layers: inout [Layer]) {
        for i in layers.indices {
            switch layers[i].content {
            case .smartObject(var so):
                if so.component?.componentID == component { so.component = nil; layers[i].content = .smartObject(so) }
            case .group(var g): unlinkInstances(of: component, in: &g.children); layers[i].content = .group(g)
            default: break
            }
        }
    }

    // MARK: Thumbnails

    private static var thumbCache: [String: CGImage] = [:]
    private static var thumbOrder: [String] = []

    /// Preview of a component variant fitted into `size` points (2× pixels) on transparency.
    static func thumbnail(_ m: ComponentMaster, variant: UUID? = nil, table: [UUID: ComponentMaster], size: CGFloat) -> CGImage? {
        // nested components change the look without bumping this component's version
        let deps = dependencies(of: [m.id], table: table).reduce(0) { $0 &+ (table[$1]?.version ?? 0) }
        let key = "\(m.id)-\(m.version)-\(deps)-\(variant?.uuidString ?? "d")-\(Int(size))"
        if let c = thumbCache[key] { return c }
        let tree = freshTree(m, variant: variant, table: table)
        var st = DocumentState(width: tree.width, height: tree.height)
        st.layers = tree.layers
        guard let cg = render(st, fit: size * 2) else { return nil }
        thumbCache[key] = cg
        thumbOrder.append(key)
        if thumbOrder.count > 200 { thumbCache[thumbOrder.removeFirst()] = nil }
        return cg
    }

    /// Composite of a state scaled to fit a square of `fit` pixels.
    static func render(_ st: DocumentState, fit: CGFloat) -> CGImage? {
        let space = CanvasSpace(width: st.width, height: st.height)
        let s = min(1, min(fit / CGFloat(st.width), fit / CGFloat(st.height)))
        let w = max(1, (CGFloat(st.width) * s).rounded()), h = max(1, (CGFloat(st.height) * s).rounded())
        let img = Compositor.shared.composite(st).cropped(to: space.ciCanvas)
            .transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        return RenderEngine.readbackContext.createCGImage(img, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGBSpace)
    }
}

/// Aspect-fill helpers for image overrides. Results are cached per (image, target) so repeated resolves return the
/// same buffer objects (keeps render caches effective and avoids re-scaling).
enum ImageFit {
    private static var cache: [String: (PixelBuffer, [PixelBuffer])] = [:]
    private static var order: [String] = []

    private static func remember(_ key: String, _ out: PixelBuffer, keep: [PixelBuffer]) {
        cache[key] = (out, keep)
        order.append(key)
        if order.count > 48 { cache[order.removeFirst()] = nil }
    }

    /// `img` centre-cropped to the given aspect ratio (width / height), at its own resolution.
    static func cropped(_ img: PixelBuffer, aspect: CGFloat) -> PixelBuffer {
        guard aspect > 0, aspect.isFinite else { return img }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        var cw = w, ch = w / aspect
        if ch > h { ch = h; cw = h * aspect }
        let iw = max(1, Int(cw.rounded())), ih = max(1, Int(ch.rounded()))
        if iw == img.width && ih == img.height { return img }
        let key = "c-\(ObjectIdentifier(img).hashValue)-\(img.version)-\(iw)x\(ih)"
        if let c = cache[key] { return c.0 }
        let out = img.cropped(to: IRect(x: (img.width - iw) / 2, y: (img.height - ih) / 2, width: iw, height: ih))
        out.markDirty()
        remember(key, out, keep: [img])
        return out
    }

    /// `img` scaled to fill `bounds` of `shape` and clipped by the shape's alpha (the placeholder's silhouette).
    static func masked(_ img: PixelBuffer, shape: PixelBuffer, bounds ob: IRect) -> PixelBuffer {
        let key = "m-\(ObjectIdentifier(img).hashValue)-\(img.version)-\(ObjectIdentifier(shape).hashValue)-\(shape.version)-\(ob.x),\(ob.y),\(ob.width),\(ob.height)"
        if let c = cache[key] { return c.0 }
        let out = shape.cropped(to: ob)
        let W = CGFloat(ob.width), H = CGFloat(ob.height)
        let s = max(W / CGFloat(img.width), H / CGFloat(img.height))
        let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
        out.drawImage(img.makeCGImage(), in: CGRect(x: (W - dw) / 2, y: (H - dh) / 2, width: dw, height: dh), blend: .sourceIn)
        out.markDirty()
        remember(key, out, keep: [img, shape])
        return out
    }
}
