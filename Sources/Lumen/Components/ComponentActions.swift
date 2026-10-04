import AppKit
import CoreImage
import ImageCratCore

/// Where the module keeps its runtime files (libraries, clipboard history). `LUMEN_SUPPORT_DIR` overrides the
/// location; self tests never touch the real Application Support folder.
enum ComponentsSupport {
    static var directory: URL = {
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        if CommandLine.arguments.contains("--selftest") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("lumen-selftest-support-\(ProcessInfo.processInfo.processIdentifier)")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Brand.supportFolderName)
    }()

    static func ensure(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
}

/// Session-wide memory of main components, so an instance pasted / dragged into another document can bring its
/// main component along.
enum ComponentRegistry {
    static var session: [UUID: ComponentMaster] = [:]

    static func remember(_ table: [UUID: ComponentMaster]) {
        for (k, v) in table { session[k] = v }
    }

    static func find(_ id: UUID) -> ComponentMaster? {
        for d in AppModel.shared.documents { if let m = d.state.components[id] { return m } }
        return session[id]
    }
}

/// Document-level component commands (each records one history step).
enum ComponentActions {
    /// Documents opened by "Edit Main Component": child document id → what it edits.
    static var editing: [UUID: (component: UUID, variant: UUID?)] = [:]

    // MARK: Commit hook

    static func installCommitHook() {
        let previous = Document.willCommit
        Document.willCommit = { d in
            previous?(d)
            willCommit(d)
        }
    }

    /// Before every history step: remember this document's components and adopt the main components of instances
    /// that arrived from elsewhere (paste, drag, duplicate-to-document).
    static func willCommit(_ d: Document) {
        if !d.state.components.isEmpty { ComponentRegistry.remember(d.state.components) }
        let used = ComponentEngine.usedComponentIDs(d.state.layers)
        guard !used.isEmpty, !used.isSubset(of: Set(d.state.components.keys)) else { return }
        var st = d.state
        let exclude = d.id
        let added = ComponentEngine.adoptMissing(&st) { id in
            for o in AppModel.shared.documents where o.id != exclude { if let m = o.state.components[id] { return m } }
            return ComponentRegistry.session[id]
        }
        if !added.isEmpty { d.state = st }
    }

    // MARK: Create

    /// Turns the selected layers into a main component and replaces them with an instance of it.
    @discardableResult
    static func createComponent(_ d: Document, name: String? = nil) -> UUID? {
        let sel = Set(d.orderedSelection)
        // a selected group already covers its selected descendants
        let ids = d.orderedSelection.filter { id in
            var p = d.state.parentID(of: id)
            while let x = p { if sel.contains(x) { return false }; p = d.state.parentID(of: x) }
            return true
        }
        let layers = ids.compactMap { d.state.layer($0) }
        guard !layers.isEmpty else { return nil }
        let base = name ?? (layers.count == 1 ? layers[0].name : "Component")
        guard let (master, rect) = ComponentEngine.makeMaster(from: layers, state: d.state, name: ComponentEngine.uniqueName(base, in: d.state.components)) else { return nil }
        var st = d.state
        st.components[master.id] = master
        guard let inst = ComponentEngine.instanceLayer(of: master.id, table: st.components, rect: rect.cgRect, name: master.name) else { return nil }
        st.insertLayer(inst, above: ids.last!)
        for id in ids { st.removeLayer(id) }
        d.state = st
        d.activeLayerID = inst.id
        d.selectedLayerIDs = [inst.id]
        d.editTarget = .content
        d.commit("Create Component")
        return master.id
    }

    /// Adds an instance of a component to the document, centred on `center` (default: middle of the view / canvas).
    @discardableResult
    static func insertInstance(_ d: Document, component: UUID, variant: UUID? = nil, center: CGPoint? = nil, commit: Bool = true) -> UUID? {
        guard let m = d.state.components[component] else { return nil }
        let t = m.tree(variant)
        var w = CGFloat(t.width), h = CGFloat(t.height)
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        let s = min(1, min(W / w, H / h))
        w *= s; h *= s
        var c = center ?? CGPoint(x: W / 2, y: H / 2)
        if center == nil, let cv = AppActions.canvas, cv.document === d, cv.bounds.width > 10 {
            let v = cv.viewToDoc(CGPoint(x: cv.bounds.midX, y: cv.bounds.midY))
            c = CGPoint(x: clamp(v.x, 0, W), y: clamp(v.y, 0, H))
        }
        let rect = CGRect(x: (c.x - w / 2).rounded(), y: (c.y - h / 2).rounded(), width: w, height: h)
        guard let layer = ComponentEngine.instanceLayer(of: component, variant: variant, table: d.state.components, rect: rect) else { return nil }
        d.addLayer(layer)
        if commit { d.commit("New Instance") }
        return layer.id
    }

    // MARK: Edit main component

    /// Opens the main component (the given variant) as a document, like Edit Contents. Saving it (⌘S) updates every
    /// instance in `d`.
    @discardableResult
    static func editMain(_ d: Document, component: UUID, variant: UUID?) -> Document? {
        guard let m = d.state.components[component] else { return nil }
        if let open = AppModel.shared.documents.first(where: { c in
            c.smartParent === d && editing[c.id].map { $0.component == component && $0.variant == variant } == true
        }) {
            AppModel.shared.activeDocumentID = open.id
            return open
        }
        let t = ComponentEngine.freshTree(m, variant: variant, table: d.state.components)
        var st = DocumentState(width: t.width, height: t.height, resolution: d.state.resolution)
        st.layers = t.layers
        st.components = d.state.components     // nested instances stay live while editing
        st.globalLight = d.state.globalLight
        let suffix = m.variants.isEmpty ? "" : " / \(m.variantName(variant))"
        let child = Document(state: st, name: "\(m.name)\(suffix) — Main Component")
        child.smartParent = d
        child.smartParentLayerID = component
        editing[child.id] = (component, variant)
        AppModel.shared.add(child)
        let n = ComponentEngine.usageCount(component, in: d.state)
        AppModel.shared.setStatus("Editing main component “\(m.name)”. Save (⌘S) to update \(n) instance\(n == 1 ? "" : "s").")
        return child
    }

    /// Hook in `AppActions.editSmartContents`: instances open their main component instead of their resolved copy.
    static func interceptEdit(_ d: Document, _ layerID: UUID) -> Bool {
        guard let inst = d.state.layer(layerID)?.componentInstance else { return false }
        if d.state.components[inst.componentID] == nil { return false }   // orphan: behaves as a plain smart object
        editMain(d, component: inst.componentID, variant: inst.variantID)
        return true
    }

    /// Hook in `AppActions.updateSmartObject`: a saved main-component document updates the table and all instances.
    static func interceptUpdate(parent: Document, child: Document) -> Bool {
        guard let e = editing[child.id] else { return false }
        commitMain(parent: parent, component: e.component, variant: e.variant, edited: child.state)
        return true
    }

    /// Stores an edited tree as the main component (variant) and rebuilds all instances.
    @discardableResult
    static func commitMain(parent: Document, component: UUID, variant: UUID?, edited: DocumentState, commitName: String = "Edit Main Component") -> Int {
        var st = parent.state
        guard var m = st.components[component] else { return 0 }
        var changed: Set<UUID> = [component]
        // components created or edited from inside the child document travel back with it
        for (k, v) in edited.components where k != component {
            if let mine = st.components[k] { if v.version > mine.version { st.components[k] = v; changed.insert(k) } }
            else { st.components[k] = v }
        }
        var layers = edited.layers
        if ComponentEngine.wouldCycle(layers, component: component, table: st.components) {
            ComponentEngine.unlinkInstances(of: component, in: &layers)
            for dep in ComponentEngine.usedComponentIDs(layers) where ComponentEngine.dependencies(of: [dep], table: st.components).contains(component) {
                ComponentEngine.unlinkInstances(of: dep, in: &layers)
            }
            AppModel.shared.setStatus("A component cannot contain itself — those instances were converted to smart objects.")
        }
        m.setTree(variant, layers: layers, width: edited.width, height: edited.height)
        m.touch()
        st.components[component] = m
        let n = ComponentEngine.refresh(&st, changed: changed)
        parent.state = st
        parent.commit(commitName)
        parent.setNeedsRender()
        return n
    }

    // MARK: Overrides

    private static func mutate(_ d: Document, _ layer: UUID, name: String, commit: Bool, _ body: (inout ComponentInstance) -> Void) {
        var st = d.state
        guard ComponentEngine.updateInstance(layer, in: &st, body) else { return }
        d.state = st
        if commit { d.commit(name) }
    }

    static func setOverride(_ d: Document, layer: UUID, _ o: ComponentOverride, commit: Bool = true) {
        mutate(d, layer, name: "Override \(o.kind.label)", commit: commit) { $0.set(o) }
    }

    static func setText(_ d: Document, layer: UUID, inner: Layer, _ text: String, commit: Bool = true) {
        var o = ComponentOverride(layerID: inner.id, layerName: inner.name, kind: .text)
        o.text = text
        setOverride(d, layer: layer, o, commit: commit)
    }

    static func setColor(_ d: Document, layer: UUID, inner: Layer, kind: ComponentOverrideKind, _ c: RGBA, commit: Bool = true) {
        var o = ComponentOverride(layerID: inner.id, layerName: inner.name, kind: kind)
        o.color = c
        setOverride(d, layer: layer, o, commit: commit)
    }

    static func setVisible(_ d: Document, layer: UUID, inner: Layer, _ v: Bool, commit: Bool = true) {
        if v == inner.isVisible { resetOverride(d, layer: layer, inner: inner.id, kind: .visible, commit: commit); return }
        var o = ComponentOverride(layerID: inner.id, layerName: inner.name, kind: .visible)
        o.visible = v
        setOverride(d, layer: layer, o, commit: commit)
    }

    static func setImage(_ d: Document, layer: UUID, inner: Layer, _ img: PixelBuffer, name: String? = nil, commit: Bool = true) {
        var o = ComponentOverride(layerID: inner.id, layerName: inner.name, kind: .image)
        o.image = img
        o.imageName = name
        setOverride(d, layer: layer, o, commit: commit)
    }

    static func resetOverride(_ d: Document, layer: UUID, inner: UUID, kind: ComponentOverrideKind, commit: Bool = true) {
        guard d.state.layer(layer)?.componentInstance?.override(inner, kind) != nil else { return }
        mutate(d, layer, name: "Reset Override", commit: commit) { $0.remove(inner, kind) }
    }

    static func setTint(_ d: Document, layer: UUID, _ tint: ComponentTint?, commit: Bool = true) {
        mutate(d, layer, name: tint == nil ? "Remove Tint" : "Tint Instance", commit: commit) { $0.tint = tint }
    }

    static func resetAll(_ d: Document, layer: UUID) {
        guard d.state.layer(layer)?.componentInstance?.hasOverrides == true else { return }
        mutate(d, layer, name: "Reset All Overrides", commit: true) { $0.overrides = []; $0.tint = nil }
    }

    static func setVariant(_ d: Document, layer: UUID, _ variant: UUID?) {
        guard let inst = d.state.layer(layer)?.componentInstance, inst.variantID != variant else { return }
        mutate(d, layer, name: "Change Variant", commit: true) { $0.variantID = variant }
    }

    /// "Push overrides to main": the instance's overrides become part of the main component.
    @discardableResult
    static func pushOverrides(_ d: Document, layer: UUID) -> Bool {
        var st = d.state
        guard ComponentEngine.pushOverrides(layer, in: &st) else { return false }
        d.state = st
        d.commit("Push Overrides to Main")
        return true
    }

    /// The instance's current look (overrides applied) becomes a new variant, which the instance then uses.
    @discardableResult
    static func saveOverridesAsVariant(_ d: Document, layer: UUID, name: String) -> UUID? {
        guard let inst = d.state.layer(layer)?.componentInstance, let m = d.state.components[inst.componentID] else { return nil }
        var tree = m.tree(inst.variantID).layers
        for o in inst.overrides { _ = ComponentEngine.apply(o, to: &tree) }
        var st = d.state
        guard let vid = ComponentEngine.addVariant(name, to: inst.componentID, basedOn: inst.variantID, layers: tree, in: &st) else { return nil }
        ComponentEngine.updateInstance(layer, in: &st) { $0.variantID = vid; $0.overrides = [] }
        d.state = st
        d.commit("New Variant")
        return vid
    }

    // MARK: Detach / swap

    /// "Detach Instance": the selected instances become ordinary (grouped) layers.
    @discardableResult
    static func detach(_ d: Document, layers: [UUID]? = nil) -> Int {
        let ids = (layers ?? d.orderedSelection).filter { d.state.layer($0)?.isComponentInstance == true }
        guard !ids.isEmpty else { return 0 }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        var st = d.state
        var n = 0
        for id in ids {
            guard let l = st.layer(id), let g = ComponentEngine.detached(l, space: sp) else { continue }
            st.updateLayer(id) { $0 = g }
            n += 1
        }
        guard n > 0 else { return 0 }
        d.state = st
        d.commit(n == 1 ? "Detach Instance" : "Detach Instances")
        return n
    }

    @discardableResult
    static func swap(_ d: Document, layer: UUID, to component: UUID) -> Bool {
        var st = d.state
        guard ComponentEngine.swap(layer, to: component, in: &st) else { return false }
        d.state = st
        d.commit("Swap Component")
        return true
    }

    // MARK: Component table

    static func rename(_ d: Document, component: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, var m = d.state.components[component], m.name != n else { return }
        let old = m.name
        m.name = n
        m.modified = Date()
        var st = d.state
        st.components[component] = m
        // instance layers still carrying the old default name follow the rename
        func ren(_ ls: inout [Layer]) {
            for i in ls.indices {
                if case .smartObject(var so) = ls[i].content, so.component?.componentID == component {
                    if ls[i].name == old { ls[i].name = n }
                    so.sourceName = n
                    ls[i].content = .smartObject(so)
                } else if case .group(var g) = ls[i].content { ren(&g.children); ls[i].content = .group(g) }
            }
        }
        ren(&st.layers)
        d.state = st
        d.commit("Rename Component")
    }

    @discardableResult
    static func duplicate(_ d: Document, component: UUID) -> UUID? {
        var st = d.state
        guard let id = ComponentEngine.duplicateComponent(component, in: &st) else { return nil }
        d.state = st
        d.commit("Duplicate Component")
        return id
    }

    static func delete(_ d: Document, component: UUID) {
        guard d.state.components[component] != nil else { return }
        var st = d.state
        ComponentEngine.deleteComponent(component, in: &st)
        d.state = st
        d.commit("Delete Component")
    }

    @discardableResult
    static func selectInstances(_ d: Document, component: UUID) -> Int {
        let ids = ComponentEngine.instances(of: component, in: d.state).map(\.id)
        guard let last = ids.last else { NSSound.beep(); return 0 }
        d.selectedLayerIDs = Set(ids)
        d.activeLayerID = last
        d.editTarget = .content
        d.setNeedsOverlay()
        return ids.count
    }

    // MARK: Variants

    @discardableResult
    static func addVariant(_ d: Document, component: UUID, name: String, basedOn: UUID? = nil) -> UUID? {
        var st = d.state
        guard let v = ComponentEngine.addVariant(name, to: component, basedOn: basedOn, in: &st) else { return nil }
        d.state = st
        d.commit("New Variant")
        return v
    }

    static func renameVariant(_ d: Document, component: UUID, variant: UUID?, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, var m = d.state.components[component] else { return }
        if let v = variant, let i = m.variants.firstIndex(where: { $0.id == v }) { m.variants[i].name = n } else { m.defaultVariantName = n }
        m.modified = Date()
        d.state.components[component] = m
        d.commit("Rename Variant")
    }

    static func deleteVariant(_ d: Document, component: UUID, variant: UUID) {
        var st = d.state
        ComponentEngine.deleteVariant(variant, of: component, in: &st)
        d.state = st
        d.commit("Delete Variant")
    }
}

// MARK: - Cross-document library (.iclib files in the support folder; .lumenlib from before the rename is read too)

struct ComponentLibraryFile: Codable {
    var id = UUID()
    var name: String
    var modified = Date()
    var components: [ComponentMaster] = []

    init(name: String) { self.name = name }

    private enum K: String, CodingKey { case id, name, modified, components }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Library"
        modified = (try? c.decodeIfPresent(Date.self, forKey: .modified)) ?? Date()
        components = (try? c.decodeIfPresent([ComponentMaster].self, forKey: .components)) ?? []
    }

    func component(_ id: UUID) -> ComponentMaster? { components.first { $0.id == id } }
}

enum ComponentLibraries {
    static var folder: URL { ComponentsSupport.directory.appendingPathComponent("Libraries") }

    /// Library files, by name.
    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { Brand.libraryExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func url(named name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = folder.appendingPathComponent(safe.isEmpty ? "Library" : safe)
        // a library created before the rename keeps its .lumenlib file (it is updated in place, not duplicated)
        let legacy = base.appendingPathExtension(Brand.Legacy.libraryExtension)
        let current = base.appendingPathExtension(Brand.libraryExtension)
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
    }

    private static var cache: [URL: (Date, ComponentLibraryFile)] = [:]

    static func load(_ url: URL) -> ComponentLibraryFile? {
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        if let c = cache[url], let mod, c.0 == mod { return c.1 }
        guard let data = try? Data(contentsOf: url), let lib = try? PropertyListDecoder().decode(ComponentLibraryFile.self, from: data) else { return nil }
        if let mod { cache[url] = (mod, lib) }
        return lib
    }

    static func save(_ lib: ComponentLibraryFile, to url: URL) throws {
        ComponentsSupport.ensure(folder)
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        var l = lib
        l.modified = Date()
        try enc.encode(l).write(to: url, options: .atomic)
        cache[url] = nil
    }

    /// Creates an empty library (or returns the existing file of that name).
    @discardableResult
    static func create(named name: String) throws -> URL {
        let u = url(named: name)
        if !FileManager.default.fileExists(atPath: u.path) { try save(ComponentLibraryFile(name: name), to: u) }
        return u
    }

    /// Saves a document component (and the components it nests) to a library. Re-saving bumps the library version.
    /// The document's component is linked to the library copy. Returns the new library version.
    @discardableResult
    static func publish(_ id: UUID, from st: inout DocumentState, to url: URL) throws -> Int {
        guard st.components[id] != nil else { return 0 }
        var lib = load(url) ?? ComponentLibraryFile(name: url.deletingPathExtension().lastPathComponent)
        var top = 0
        for cid in ComponentEngine.dependencies(of: [id], table: st.components) {
            guard var m = st.components[cid] else { continue }
            let prev = lib.component(cid)
            if cid != id, prev != nil { continue }     // nested dependencies are only added when missing
            let v = (prev?.version ?? 0) + 1
            m.library = ComponentLibraryLink(libraryID: lib.id, libraryName: lib.name, version: v)
            st.components[cid] = m
            var stored = m
            stored.version = v
            stored.modified = Date()
            lib.components.removeAll { $0.id == cid }
            lib.components.append(stored)
            if cid == id { top = v }
        }
        try save(lib, to: url)
        return top
    }

    /// Copies a library component (with nested dependencies) into a document's table when it is not there yet.
    /// Returns false when the library does not have it.
    @discardableResult
    static func place(_ id: UUID, from lib: ComponentLibraryFile, into st: inout DocumentState) -> Bool {
        guard lib.component(id) != nil else { return false }
        let table = Dictionary(lib.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for cid in ComponentEngine.dependencies(of: [id], table: table) where st.components[cid] == nil {
            guard var m = table[cid] else { continue }
            m.library = ComponentLibraryLink(libraryID: lib.id, libraryName: lib.name, version: m.version)
            st.components[cid] = m
        }
        return true
    }

    static func remove(_ id: UUID, from url: URL) throws {
        guard var lib = load(url) else { return }
        lib.components.removeAll { $0.id == id }
        try save(lib, to: url)
    }

    /// The library copy of a linked component when it is newer than the document's.
    static func newerVersion(of m: ComponentMaster) -> ComponentMaster? {
        guard let link = m.library else { return nil }
        for u in list() {
            guard let lib = load(u), lib.id == link.libraryID, let c = lib.component(m.id) else { continue }
            return c.version > link.version ? c : nil
        }
        return nil
    }

    /// "Update from library": replaces the document's component content with the newer library version and rebuilds
    /// all instances (overrides are kept where the inner layers still exist).
    @discardableResult
    static func update(_ id: UUID, in st: inout DocumentState) -> Bool {
        guard let mine = st.components[id], let newer = newerVersion(of: mine), let link = mine.library else { return false }
        var m = newer
        m.version = mine.version + 1
        m.created = mine.created
        m.library = ComponentLibraryLink(libraryID: link.libraryID, libraryName: link.libraryName, version: newer.version)
        st.components[id] = m
        // instances on a variant that no longer exists fall back to the default
        let valid = Set(m.variants.map(\.id))
        ComponentEngine.mapInstances(&st.layers) { inst in
            if inst.componentID == id, let v = inst.variantID, !valid.contains(v) { inst.variantID = nil }
        }
        ComponentEngine.refresh(&st, changed: [id])
        return true
    }
}
