import Foundation

// MARK: - Brush library model (persisted as Brushes/library.json)
//
// Folders form a tree (folders first, then brushes, each in the user's order). Brush records reference tips by id;
// tip images live as PNG files next to the index (`Tips/<file>`), patterns for brush textures in `Patterns/`.
// All tree edits are pure value operations here, so they are unit tested without the app; the app's `BrushLibrary`
// wraps an index, adds undo, images and persistence.

package struct BrushTipRecord: Codable, Equatable {
    package var id: String
    /// PNG file names in the library's Tips folder, one per frame.
    package var files: [String]
    package var selection: BrushFrameSelection = .incremental
    package init(id: String, files: [String], selection: BrushFrameSelection = .incremental) {
        self.id = id; self.files = files; self.selection = selection
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        files = (try? c.decodeIfPresent([String].self, forKey: .files)) ?? []
        selection = (try? c.decodeIfPresent(BrushFrameSelection.self, forKey: .selection)) ?? .incremental
    }
}

package struct BrushPatternRecord: Codable, Equatable {
    package var id: String
    package var name: String
    package var file: String
    package init(id: String, name: String, file: String) { self.id = id; self.name = name; self.file = file }
}

package struct BrushRecord: Codable, Equatable, Identifiable {
    package var id: String
    package var name: String
    /// "round" (computed), a procedural tip id ("chalk", "charcoal", …) or the id of a `BrushTipRecord`.
    package var tipID: String
    package var params: BrushParams
    /// The preset sets the brush size when chosen (Photoshop's "Capture Brush Size in Preset").
    package var includesSize = true
    /// The preset sets opacity, flow, blend mode and smoothing when chosen ("Include Tool Settings").
    package var includesToolSettings = false
    /// The preset sets the foreground colour when chosen ("Include Color").
    package var color: RGBA?
    /// Shipped with the app (default set); still editable, deletable and restorable.
    package var builtIn = false
    /// Where it came from ("Kyle's Inkers.abr", "Defined from selection", …).
    package var source: String = ""
    package var created: Date?

    package init(id: String, name: String, tipID: String, params: BrushParams, includesSize: Bool = true, includesToolSettings: Bool = false,
                 color: RGBA? = nil, builtIn: Bool = false, source: String = "", created: Date? = nil) {
        self.id = id; self.name = name; self.tipID = tipID; self.params = params; self.includesSize = includesSize
        self.includesToolSettings = includesToolSettings; self.color = color; self.builtIn = builtIn; self.source = source; self.created = created
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Brush"
        tipID = (try? c.decodeIfPresent(String.self, forKey: .tipID)) ?? "round"
        params = (try? c.decodeIfPresent(BrushParams.self, forKey: .params)) ?? BrushParams()
        includesSize = (try? c.decodeIfPresent(Bool.self, forKey: .includesSize)) ?? true
        includesToolSettings = (try? c.decodeIfPresent(Bool.self, forKey: .includesToolSettings)) ?? false
        color = try? c.decodeIfPresent(RGBA.self, forKey: .color)
        builtIn = (try? c.decodeIfPresent(Bool.self, forKey: .builtIn)) ?? false
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        created = try? c.decodeIfPresent(Date.self, forKey: .created)
    }
}

package struct BrushFolderNode: Codable, Equatable, Identifiable {
    package var id: String
    package var name: String
    package var expanded = true
    package var folders: [BrushFolderNode] = []
    package var brushes: [String] = []
    package init(id: String, name: String, expanded: Bool = true, folders: [BrushFolderNode] = [], brushes: [String] = []) {
        self.id = id; self.name = name; self.expanded = expanded; self.folders = folders; self.brushes = brushes
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Folder"
        expanded = (try? c.decodeIfPresent(Bool.self, forKey: .expanded)) ?? true
        folders = (try? c.decodeIfPresent([BrushFolderNode].self, forKey: .folders)) ?? []
        brushes = (try? c.decodeIfPresent([String].self, forKey: .brushes)) ?? []
    }
}

package struct BrushLibraryIndex: Codable, Equatable {
    package static let currentVersion = 2
    package static let rootID = "root"
    package static let maxRecent = 10

    package var version = BrushLibraryIndex.currentVersion
    package var root = BrushFolderNode(id: BrushLibraryIndex.rootID, name: "Brushes")
    package var brushes: [String: BrushRecord] = [:]
    package var tips: [String: BrushTipRecord] = [:]
    package var patterns: [BrushPatternRecord] = []
    package var favorites: [String] = []
    /// Most recent first.
    package var recent: [String] = []
    /// Version of the default set that was installed (later versions add new defaults without re-adding deleted ones).
    package var defaultsVersion = 0
    /// Ids of default brushes the user deleted (not re-added by a defaults update).
    package var deletedDefaults: [String] = []

    package init() {}

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        root = (try? c.decodeIfPresent(BrushFolderNode.self, forKey: .root)) ?? BrushFolderNode(id: BrushLibraryIndex.rootID, name: "Brushes")
        // Records one by one: a damaged record is dropped, not the library.
        if let raw = try? c.decodeIfPresent([String: LenientRecord].self, forKey: .brushes) {
            for (k, v) in raw { if let r = v.value { brushes[k] = r } }
        }
        tips = (try? c.decodeIfPresent([String: BrushTipRecord].self, forKey: .tips)) ?? [:]
        patterns = (try? c.decodeIfPresent([BrushPatternRecord].self, forKey: .patterns)) ?? []
        favorites = (try? c.decodeIfPresent([String].self, forKey: .favorites)) ?? []
        recent = (try? c.decodeIfPresent([String].self, forKey: .recent)) ?? []
        defaultsVersion = (try? c.decodeIfPresent(Int.self, forKey: .defaultsVersion)) ?? 0
        deletedDefaults = (try? c.decodeIfPresent([String].self, forKey: .deletedDefaults)) ?? []
        repair()
    }

    private struct LenientRecord: Decodable {
        var value: BrushRecord?
        init(from decoder: Decoder) throws { value = try? BrushRecord(from: decoder) }
    }

    // MARK: Queries

    /// Every brush id in display order (depth first: a folder's subfolders, then its brushes).
    package var orderedBrushIDs: [String] {
        var out: [String] = []
        func walk(_ f: BrushFolderNode) {
            for s in f.folders { walk(s) }
            out += f.brushes
        }
        walk(root)
        return out
    }

    package func folder(_ id: String) -> BrushFolderNode? {
        func find(_ f: BrushFolderNode) -> BrushFolderNode? {
            if f.id == id { return f }
            for s in f.folders { if let r = find(s) { return r } }
            return nil
        }
        return find(root)
    }

    /// The folder holding a brush.
    package func folderID(ofBrush id: String) -> String? {
        func find(_ f: BrushFolderNode) -> String? {
            if f.brushes.contains(id) { return f.id }
            for s in f.folders { if let r = find(s) { return r } }
            return nil
        }
        return find(root)
    }

    /// Names from the top level down to the folder (empty for the root).
    package func path(ofFolder id: String) -> [String] {
        func find(_ f: BrushFolderNode, _ trail: [String]) -> [String]? {
            if f.id == id { return trail }
            for s in f.folders { if let r = find(s, trail + [s.name]) { return r } }
            return nil
        }
        return find(root, []) ?? []
    }

    package func parentID(ofFolder id: String) -> String? {
        func find(_ f: BrushFolderNode) -> String? {
            if f.folders.contains(where: { $0.id == id }) { return f.id }
            for s in f.folders { if let r = find(s) { return r } }
            return nil
        }
        return find(root)
    }

    /// Brush ids inside a folder and all its subfolders.
    package func brushIDs(inFolder id: String, recursive: Bool = true) -> [String] {
        guard let f = folder(id) else { return [] }
        var out: [String] = []
        func walk(_ n: BrushFolderNode) {
            if recursive { for s in n.folders { walk(s) } }
            out += n.brushes
        }
        walk(f)
        return out
    }

    /// Every folder with its path, depth first (for menus and the folder filter).
    package var allFolders: [(id: String, path: [String])] {
        var out: [(String, [String])] = []
        func walk(_ f: BrushFolderNode, _ trail: [String]) {
            for s in f.folders {
                out.append((s.id, trail + [s.name]))
                walk(s, trail + [s.name])
            }
        }
        walk(root, [])
        return out
    }

    /// Case- and diacritic-insensitive search; every word must match the brush name, its folder path or its source.
    /// `folderID` limits the result to a folder (and its subfolders).
    package func search(_ query: String, inFolder folderID: String? = nil) -> [String] {
        let scope = folderID.map { brushIDs(inFolder: $0) } ?? orderedBrushIDs
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard !words.isEmpty else { return scope }
        var folderPathCache: [String: String] = [:]
        return scope.filter { id in
            guard let b = brushes[id] else { return false }
            let fid = self.folderID(ofBrush: id) ?? BrushLibraryIndex.rootID
            let fpath: String
            if let c = folderPathCache[fid] { fpath = c } else { fpath = path(ofFolder: fid).joined(separator: " "); folderPathCache[fid] = fpath }
            let hay = (b.name + " " + fpath + " " + b.source).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: Folder edits

    private mutating func edit(_ id: String, _ f: (inout BrushFolderNode) -> Void) -> Bool {
        func walk(_ n: inout BrushFolderNode) -> Bool {
            if n.id == id { f(&n); return true }
            for i in n.folders.indices { if walk(&n.folders[i]) { return true } }
            return false
        }
        return walk(&root)
    }

    /// Creates a folder (unique name among its siblings) and returns its id.
    @discardableResult
    package mutating func createFolder(_ name: String, in parentID: String = BrushLibraryIndex.rootID, id: String? = nil, at index: Int? = nil) -> String {
        let fid = id ?? "f-" + UUID().uuidString.prefix(8).lowercased()
        let siblings = (folder(parentID) ?? root).folders.map(\.name)
        let n = Self.uniqueName(name.isEmpty ? "New Folder" : name, among: siblings)
        let target = folder(parentID) == nil ? BrushLibraryIndex.rootID : parentID
        _ = edit(target) { p in
            let node = BrushFolderNode(id: fid, name: n)
            if let i = index { p.folders.insert(node, at: max(0, min(p.folders.count, i))) } else { p.folders.append(node) }
        }
        return fid
    }

    /// Folder for a path below `parentID`, created as needed (import groups).
    package mutating func folder(path: [String], in parentID: String = BrushLibraryIndex.rootID) -> String {
        var cur = parentID
        for name in path {
            if let existing = folder(cur)?.folders.first(where: { $0.name == name }) { cur = existing.id }
            else { cur = createFolder(name, in: cur) }
        }
        return cur
    }

    package mutating func renameFolder(_ id: String, to name: String) {
        guard id != BrushLibraryIndex.rootID else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        _ = edit(id) { $0.name = n }
    }

    package mutating func setExpanded(_ id: String, _ on: Bool) { _ = edit(id) { $0.expanded = on } }

    /// Removes a folder and returns the brush ids that were inside it (the records are removed too).
    @discardableResult
    package mutating func deleteFolder(_ id: String) -> [String] {
        guard id != BrushLibraryIndex.rootID, let pid = parentID(ofFolder: id) else { return [] }
        let ids = brushIDs(inFolder: id)
        _ = edit(pid) { $0.folders.removeAll { $0.id == id } }
        for b in ids { forgetBrush(b) }
        return ids
    }

    /// Moves a folder under another one (not into itself or its own subfolders).
    @discardableResult
    package mutating func moveFolder(_ id: String, to newParent: String, at index: Int? = nil) -> Bool {
        guard id != BrushLibraryIndex.rootID, id != newParent, let node = folder(id), let pid = parentID(ofFolder: id), folder(newParent) != nil else { return false }
        func contains(_ n: BrushFolderNode, _ target: String) -> Bool { n.folders.contains { $0.id == target || contains($0, target) } }
        if contains(node, newParent) { return false }
        var insertAt = index
        if pid == newParent, let i = index, let cur = folder(pid)?.folders.firstIndex(where: { $0.id == id }), cur < i { insertAt = i - 1 }
        _ = edit(pid) { $0.folders.removeAll { $0.id == id } }
        _ = edit(newParent) { p in
            var n = node
            n.name = Self.uniqueName(node.name, among: p.folders.map(\.name))
            if let i = insertAt { p.folders.insert(n, at: max(0, min(p.folders.count, i))) } else { p.folders.append(n) }
        }
        return true
    }

    // MARK: Brush edits

    /// Adds a record into a folder (at the end, or at `index`).
    package mutating func add(_ r: BrushRecord, to folderID: String = BrushLibraryIndex.rootID, at index: Int? = nil) {
        brushes[r.id] = r
        let target = folder(folderID) == nil ? BrushLibraryIndex.rootID : folderID
        _ = edit(target) { f in
            f.brushes.removeAll { $0 == r.id }
            if let i = index { f.brushes.insert(r.id, at: max(0, min(f.brushes.count, i))) } else { f.brushes.append(r.id) }
        }
    }

    /// Moves brushes (in the given order) into a folder at an index (end when nil). Returns false when nothing moved.
    @discardableResult
    package mutating func moveBrushes(_ ids: [String], to folderID: String, at index: Int? = nil) -> Bool {
        let movable = ids.filter { brushes[$0] != nil }
        guard !movable.isEmpty, folder(folderID) != nil else { return false }
        var insertAt = index
        if let i = index, let f = folder(folderID) {
            // Items above the drop point that move away shift the index.
            insertAt = i - f.brushes.prefix(max(0, min(i, f.brushes.count))).filter { movable.contains($0) }.count
        }
        func strip(_ n: inout BrushFolderNode) {
            n.brushes.removeAll { movable.contains($0) }
            for i in n.folders.indices { strip(&n.folders[i]) }
        }
        strip(&root)
        _ = edit(folderID) { f in
            let at = insertAt.map { max(0, min(f.brushes.count, $0)) } ?? f.brushes.count
            f.brushes.insert(contentsOf: movable, at: at)
        }
        return true
    }

    package mutating func rename(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        brushes[id]?.name = n
    }

    /// Copies a brush next to the original ("Name copy", "Name copy 2", …); returns the new id.
    @discardableResult
    package mutating func duplicate(_ id: String, newID: String? = nil) -> String? {
        guard var r = brushes[id], let fid = folderID(ofBrush: id) else { return nil }
        let nid = newID ?? "b-" + UUID().uuidString.prefix(8).lowercased()
        let names = brushIDs(inFolder: fid, recursive: false).compactMap { brushes[$0]?.name }
        r.id = nid
        r.name = Self.uniqueName(r.name + " copy", among: names)
        r.builtIn = false
        r.created = Date()
        let idx = folder(fid)?.brushes.firstIndex(of: id).map { $0 + 1 }
        add(r, to: fid, at: idx)
        return nid
    }

    /// Removes a brush from the tree, favourites and recent.
    package mutating func remove(_ id: String) {
        if let r = brushes[id], r.builtIn, !deletedDefaults.contains(id) { deletedDefaults.append(id) }
        forgetBrush(id)
    }

    private mutating func forgetBrush(_ id: String) {
        func strip(_ n: inout BrushFolderNode) {
            n.brushes.removeAll { $0 == id }
            for i in n.folders.indices { strip(&n.folders[i]) }
        }
        strip(&root)
        brushes.removeValue(forKey: id)
        favorites.removeAll { $0 == id }
        recent.removeAll { $0 == id }
    }

    package mutating func setFavorite(_ id: String, _ on: Bool) {
        guard brushes[id] != nil else { return }
        favorites.removeAll { $0 == id }
        if on { favorites.append(id) }
    }

    package func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    /// Marks a brush as just used (front of Recent, at most `maxRecent`).
    package mutating func noteUsed(_ id: String) {
        guard brushes[id] != nil else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
    }

    // MARK: Integrity

    /// Tip ids no brush refers to (as its tip or its dual tip).
    package var unreferencedTips: [String] {
        var used = Set<String>()
        for b in brushes.values { used.insert(b.tipID); used.insert(b.params.dualTipID) }
        return tips.keys.filter { !used.contains($0) }.sorted()
    }

    /// Repairs an index read from disk: brushes in the tree without a record are dropped, records not in the tree
    /// are put at the top level, a brush listed twice keeps its first place, favourites / recent lose unknown ids.
    package mutating func repair() {
        var seen = Set<String>()
        var seenFolders = Set<String>()
        func fix(_ n: inout BrushFolderNode) {
            n.brushes = n.brushes.filter { brushes[$0] != nil && seen.insert($0).inserted }
            n.folders = n.folders.filter { seenFolders.insert($0.id).inserted }
            for i in n.folders.indices { fix(&n.folders[i]) }
        }
        root.id = BrushLibraryIndex.rootID
        fix(&root)
        for id in brushes.keys.sorted() where !seen.contains(id) { root.brushes.append(id) }
        favorites = favorites.filter { brushes[$0] != nil }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        recent = Array(recent.filter { brushes[$0] != nil }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(Self.maxRecent))
    }

    // MARK: Encoding

    package func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    package static func decode(_ data: Data) throws -> BrushLibraryIndex {
        let d = JSONDecoder()
        return try d.decode(BrushLibraryIndex.self, from: data)
    }

    package static func uniqueName(_ base: String, among names: [String]) -> String {
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
