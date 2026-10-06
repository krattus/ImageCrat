import AppKit
import Observation
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// The brush library: every brush preset (defaults, imported, defined, saved), in folders, with favourites, recent
/// brushes, search, undo for edits, import / export, and the tips and texture patterns the presets use.
///
/// Stored in `Brand.supportFolder/Brushes/`: `library.json` (a `BrushLibraryIndex`), `Tips/*.png` (gray, white =
/// paint), `Patterns/*.png`, `prefs.json`. Automated runs get Brand's temporary support folder.
///
/// API for other UI (the canvas quick picker): `recentBrushes`, `favoriteBrushes`, `orderedBrushes`,
/// `thumbnail(_:size:)`, `strokePreview(_:width:height:)`, `select(_:)`, `choose(_:into:tool:)`, `activePresetID(for:)`.
/// The library is the only store of favourites, recent brushes and the preset each tool's brush came from.
@Observable
final class BrushLibrary {
    static let shared = BrushLibrary()

    struct Prefs: Codable, Equatable {
        enum ViewMode: String, Codable, CaseIterable { case tips, strokes, list }
        var viewMode: ViewMode = .tips
        /// Thumbnail size in the panel (points).
        var thumbSize: Double = 44
        /// Choosing a preset keeps the current size even when the preset includes one.
        var keepSize = false
        /// Choosing a preset that includes a colour sets the foreground colour.
        var applyColor = true
        /// Collapsed state of the Favourites / Recent sections.
        var favoritesCollapsed = false
        var recentCollapsed = false
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            viewMode = (try? c.decodeIfPresent(ViewMode.self, forKey: .viewMode)) ?? .tips
            thumbSize = (try? c.decodeIfPresent(Double.self, forKey: .thumbSize)) ?? 44
            keepSize = (try? c.decodeIfPresent(Bool.self, forKey: .keepSize)) ?? false
            applyColor = (try? c.decodeIfPresent(Bool.self, forKey: .applyColor)) ?? true
            favoritesCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .favoritesCollapsed)) ?? false
            recentCollapsed = (try? c.decodeIfPresent(Bool.self, forKey: .recentCollapsed)) ?? false
        }
    }

    /// The library's contents (observed by the panels).
    private(set) var index = BrushLibraryIndex()
    var prefs = Prefs() { didSet { if prefs != oldValue { savePrefs() } } }
    /// Bumped on every change (thumbnail caches key on it).
    private(set) var revision = 0
    /// Preset last chosen per tool (`ToolKind.rawValue` → brush id).
    var activePresetIDs: [String: String] = [:]
    /// Title of the edit Undo / Redo would revert (nil: nothing to undo).
    private(set) var undoName: String?
    private(set) var redoName: String?
    /// An import running in the background.
    struct ImportProgress: Equatable { var done: Int; var total: Int; var current: String }
    private(set) var importProgress: ImportProgress?
    /// Summary of the last import ("Imported 248 brushes into “Kyle's Inkers”; 3 skipped: …").
    private(set) var lastImportSummary: String?

    @ObservationIgnored let directory: URL
    @ObservationIgnored private var tipCache: [String: (buffers: [PixelBuffer], selection: BrushFrameSelection)] = [:]
    @ObservationIgnored private var undoStack: [(String, BrushLibraryIndex)] = []
    @ObservationIgnored private var redoStack: [(String, BrushLibraryIndex)] = []
    @ObservationIgnored private var thumbCache: [String: CGImage] = [:]
    @ObservationIgnored private var saveScheduled = false
    /// Settings a preset produced when it was chosen (per tool), for the modified mark.
    @ObservationIgnored private var appliedParams: [String: BrushParams] = [:]

    static let maxTipSide = 2500
    static let maxUndo = 50

    var indexURL: URL { directory.appendingPathComponent("library.json") }
    var tipsDir: URL { directory.appendingPathComponent("Tips", isDirectory: true) }
    var patternsDir: URL { directory.appendingPathComponent("Patterns", isDirectory: true) }
    private var prefsURL: URL { directory.appendingPathComponent("prefs.json") }

    static var defaultDirectory: URL {
        Brand.supportFolder.appendingPathComponent("Brushes", isDirectory: true)
    }

    init(directory: URL = BrushLibrary.defaultDirectory, installDefaults: Bool = true) {
        self.directory = directory
        load(installDefaults: installDefaults)
        Self.instances.add(self)
    }

    /// Every live library (the app has one; tests open more). Tip ids are unique, so the rasterizer can find a tip in
    /// whichever library holds it.
    @ObservationIgnored nonisolated(unsafe) private static var instances = NSHashTable<BrushLibrary>.weakObjects()

    /// Frames of a tip from any library (the shared one first).
    static func tipFramesAnywhere(_ id: String) -> (buffers: [PixelBuffer], selection: BrushFrameSelection)? {
        if let f = shared.tipFrames(id) { return f }
        for l in instances.allObjects where l !== shared { if let f = l.tipFrames(id) { return f } }
        return nil
    }

    // MARK: - Queries

    func record(_ id: String) -> BrushRecord? { index.brushes[id] }
    var orderedBrushes: [BrushRecord] { index.orderedBrushIDs.compactMap { index.brushes[$0] } }
    var recentBrushes: [BrushRecord] { index.recent.compactMap { index.brushes[$0] } }
    var favoriteBrushes: [BrushRecord] { index.favorites.compactMap { index.brushes[$0] } }
    func isFavorite(_ id: String) -> Bool { index.isFavorite(id) }
    func contains(_ id: String) -> Bool { index.brushes[id] != nil }

    /// Frame 0 of a library tip (gray, white = paint).
    func tipBuffer(_ id: String) -> PixelBuffer? { tipFrames(id)?.buffers.first }

    /// Every frame of a library tip.
    func tipFrames(_ id: String) -> (buffers: [PixelBuffer], selection: BrushFrameSelection)? {
        if let c = tipCache[id] { return c }
        guard let t = index.tips[id] else { return nil }
        var bufs: [PixelBuffer] = []
        for f in t.files {
            let url = tipsDir.appendingPathComponent(f)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            bufs.append(PixelBuffer(cgImage: img, format: .gray))
        }
        guard !bufs.isEmpty else { return nil }
        tipCache[id] = (bufs, t.selection)
        return tipCache[id]
    }

    /// Ids of the tips a tip picker offers: round, the procedural ones, then the library's image tips.
    var tipChoices: [String] {
        var ids = ["round"] + BrushTips.textured
        for r in orderedBrushes where !ids.contains(r.tipID) { ids.append(r.tipID) }
        return ids
    }

    func tipName(_ tipID: String) -> String {
        if tipID == "round" { return "Round" }
        if BrushTips.textured.contains(tipID) { return tipID.capitalized }
        return orderedBrushes.first { $0.tipID == tipID }?.name ?? "Custom Tip"
    }

    /// Settings for a preset, starting from `base` (keeps what the preset doesn't include).
    func settings(for r: BrushRecord, base: BrushSettings) -> BrushSettings {
        var s = base
        s.apply(r.params, tipID: r.tipID, includesSize: r.includesSize && !prefs.keepSize, includesToolSettings: r.includesToolSettings)
        return s
    }

    /// Settings of a preset on its own (default tool settings) — previews, thumbnails.
    func standaloneSettings(_ r: BrushRecord) -> BrushSettings {
        var s = BrushSettings()
        s.pressureSize = false
        s.apply(r.params, tipID: r.tipID, includesSize: true, includesToolSettings: r.includesToolSettings)
        return s
    }

    // MARK: - Choosing brushes

    private func toolKey(_ t: ToolKind? = nil) -> String { (t ?? AppModel.shared.tool).rawValue }

    /// The preset last chosen for the current tool.
    var activePresetID: String? { activePresetID(for: AppModel.shared.tool) }
    /// The preset a tool's brush came from (nil: none, or it was deleted).
    func activePresetID(for tool: ToolKind) -> String? { activePresetIDs[tool.rawValue].flatMap { index.brushes[$0] != nil ? $0 : nil } }
    var activePreset: BrushRecord? { activePresetID.flatMap { index.brushes[$0] } }

    /// Applies a preset to the current brush tool (or the Brush tool when the current tool has no brush).
    func select(_ id: String) {
        guard index.brushes[id] != nil else { return }
        let app = AppModel.shared
        if !AppModel.hasBrush(app.tool) { app.tool = .brush }
        var s = app.activeBrushSettings
        choose(id, into: &s)
        app.activeBrushSettings = s
    }

    /// Applies a preset to settings (the options-bar pop-overs bind to a tool's settings; the canvas quick picker
    /// passes the tool it opened for): size / tool settings / colour as the preset includes them, Recent, the
    /// modified mark, and the tool's active preset (`tool` nil: the current tool).
    func choose(_ id: String, into s: inout BrushSettings, tool: ToolKind? = nil) {
        guard let r = index.brushes[id] else { return }
        let app = AppModel.shared
        s = settings(for: r, base: s)
        if let c = r.color, prefs.applyColor { app.foreground = c }
        activePresetIDs[toolKey(tool)] = id
        appliedParams[toolKey(tool)] = comparable(s)
        index.noteUsed(id)          // (not an undo step; thumbnails stay cached)
        scheduleSave()
        app.setStatus("Brush: \(r.name)")
    }

    /// Preferences ▸ Tablet ▸ Sync brush across tools: the tip of `old` was carried to `new` (`BrushMemory.copyTip`),
    /// so the preset it came from (and its modified state) goes along. Without sync each tool keeps its own.
    func toolBrushSynced(from old: ToolKind, to new: ToolKind) {
        let o = old.rawValue, n = new.rawValue
        if let id = activePresetIDs[o] { activePresetIDs[n] = id } else { activePresetIDs.removeValue(forKey: n) }
        if let a = appliedParams[o] { appliedParams[n] = a } else { appliedParams.removeValue(forKey: n) }
    }

    /// Favourites and recent brushes the quick brush picker kept on its own before it used the library
    /// (`TabletPrefs` legacy keys): ids of library brushes are merged in once (favourites appended, recent ones after
    /// the library's own), unknown ids dropped. Not an undo step. Returns how many ids were taken over.
    @discardableResult
    func mergeLegacyLists(favorites: [String], recent: [String]) -> Int {
        var ix = index
        var n = 0
        for id in favorites where ix.brushes[id] != nil && !ix.isFavorite(id) { ix.setFavorite(id, true); n += 1 }
        var r = ix.recent
        for id in recent where ix.brushes[id] != nil && !r.contains(id) && r.count < BrushLibraryIndex.maxRecent { r.append(id); n += 1 }
        ix.recent = r
        guard ix != index else { return 0 }
        index = ix
        revision += 1
        scheduleSave()
        return n
    }

    /// Favourites, Recent and the per-tool presets (self tests put them back afterwards; not an undo step).
    struct ChoiceState { fileprivate var favorites: [String]; fileprivate var recent: [String]; fileprivate var active: [String: String]; fileprivate var applied: [String: BrushParams] }
    var choiceState: ChoiceState { ChoiceState(favorites: index.favorites, recent: index.recent, active: activePresetIDs, applied: appliedParams) }
    func restore(_ c: ChoiceState) {
        index.favorites = c.favorites.filter { index.brushes[$0] != nil }
        index.recent = c.recent.filter { index.brushes[$0] != nil }
        activePresetIDs = c.active
        appliedParams = c.applied
        revision += 1
        scheduleSave()
    }

    // MARK: - Drag and drop in the panel

    /// Drag payloads: "icbrush:<id>,<id>…" (brushes) or "icfolder:<id>".
    static func dragPayload(brushes ids: [String]) -> String { "icbrush:" + ids.joined(separator: ",") }
    static func dragPayload(folder id: String) -> String { "icfolder:" + id }

    /// Handles a drop of an internal payload onto a folder (`before`: a brush of that folder to insert in front of,
    /// nil = at the end). Returns false for payloads that aren't ours or moves that aren't possible.
    @discardableResult
    func handleDrop(_ payload: String, folder: String, before: String? = nil) -> Bool {
        if payload.hasPrefix("icbrush:") {
            let ids = payload.dropFirst("icbrush:".count).split(separator: ",").map(String.init).filter { index.brushes[$0] != nil }
            guard !ids.isEmpty, index.folder(folder) != nil else { return false }
            let at = before.flatMap { b in index.folder(folder)?.brushes.firstIndex(of: b) }
            move(ids, to: folder, at: at)
            return true
        }
        if payload.hasPrefix("icfolder:") {
            let fid = String(payload.dropFirst("icfolder:".count))
            guard fid != folder, index.folder(fid) != nil else { return false }
            let before = index
            moveFolder(fid, to: folder)
            return index != before
        }
        return false
    }

    /// The parts of the settings a preset owns (for the modified mark).
    private func comparable(_ s: BrushSettings) -> BrushParams {
        var p = BrushParams(s)
        p.opacity = 1; p.flow = 1; p.blendMode = "normal"; p.smoothing = 0; p.pressureSize = true; p.pressureOpacity = false
        return p
    }

    /// The current tool's settings differ from the preset as it was chosen (Photoshop marks the preset as modified).
    var isActivePresetModified: Bool {
        guard activePreset != nil, let applied = appliedParams[toolKey()] else { return false }
        return comparable(AppModel.shared.activeBrushSettings) != applied || AppModel.shared.activeBrushSettings.tipID != activePreset?.tipID
    }

    /// Writes the current settings into the active preset.
    func saveChangesToActivePreset() {
        guard let id = activePresetID else { return }
        saveSettings(AppModel.shared.activeBrushSettings, to: id)
        appliedParams[toolKey()] = comparable(AppModel.shared.activeBrushSettings)
    }

    func saveSettings(_ s: BrushSettings, to id: String) {
        guard let r = index.brushes[id] else { return }
        perform("Save Brush “\(r.name)”") { ix in
            ix.brushes[id]?.params = BrushParams(s)
            ix.brushes[id]?.tipID = s.tipID
        }
    }

    /// Re-applies the active preset (drops changes made since it was chosen).
    func resetActivePreset() {
        guard let id = activePresetID else { return }
        select(id)
    }

    // MARK: - Edits (undoable)

    /// Applies an edit to the index with an undo step.
    func perform(_ name: String, _ change: (inout BrushLibraryIndex) -> Void) {
        let before = index
        var ix = index
        change(&ix)
        guard ix != before else { return }
        undoStack.append((name, before))
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        index = ix
        changed()
    }

    func undo() {
        guard let (name, prev) = undoStack.popLast() else { return }
        redoStack.append((name, index))
        index = prev
        changed()
        AppModel.shared.setStatus("Undo \(name)")
    }

    func redo() {
        guard let (name, next) = redoStack.popLast() else { return }
        undoStack.append((name, index))
        index = next
        changed()
        AppModel.shared.setStatus("Redo \(name)")
    }

    private func changed() {
        undoName = undoStack.last?.0
        redoName = redoStack.last?.0
        revision += 1
        thumbCache.removeAll()
        scheduleSave()
    }

    @discardableResult
    func createFolder(_ name: String = "New Folder", in parent: String = BrushLibraryIndex.rootID) -> String {
        var fid = ""
        perform("New Folder") { fid = $0.createFolder(name, in: parent) }
        return fid
    }

    func renameFolder(_ id: String, to name: String) { perform("Rename Folder") { $0.renameFolder(id, to: name) } }
    func setExpanded(_ id: String, _ on: Bool) {
        // (not an undo step)
        index.setExpanded(id, on)
        scheduleSave()
    }

    func deleteFolder(_ id: String, confirm: Bool = true) {
        guard let f = index.folder(id) else { return }
        let n = index.brushIDs(inFolder: id).count
        if confirm && n > 0 && !Self.confirm("Delete the folder “\(f.name)” and its \(n) brush\(n == 1 ? "" : "es")?", "You can undo this in the Brushes panel menu.") { return }
        perform("Delete Folder") { $0.deleteFolder(id) }
    }

    func moveFolder(_ id: String, to parent: String, at index: Int? = nil) { perform("Move Folder") { $0.moveFolder(id, to: parent, at: index) } }
    func move(_ ids: [String], to folder: String, at index: Int? = nil) { perform(ids.count == 1 ? "Move Brush" : "Move Brushes") { $0.moveBrushes(ids, to: folder, at: index) } }
    func rename(_ id: String, to name: String) { perform("Rename Brush") { $0.rename(id, to: name) } }

    @discardableResult
    func duplicate(_ id: String) -> String? {
        var nid: String?
        perform("Duplicate Brush") { nid = $0.duplicate(id) }
        return nid
    }

    func delete(_ ids: [String], confirm: Bool = true) {
        let names = ids.compactMap { index.brushes[$0]?.name }
        guard !names.isEmpty else { return }
        let what = names.count == 1 ? "“\(names[0])”" : "\(names.count) brushes"
        if confirm && !Self.confirm("Delete \(what)?", "You can undo this in the Brushes panel menu.") { return }
        perform(names.count == 1 ? "Delete Brush" : "Delete Brushes") { ix in for id in ids { ix.remove(id) } }
    }

    func setFavorite(_ id: String, _ on: Bool) { perform(on ? "Add to Favorites" : "Remove from Favorites") { $0.setFavorite(id, on) } }

    func setFlags(_ id: String, includesSize: Bool? = nil, includesToolSettings: Bool? = nil, color: RGBA?? = nil) {
        perform("Change Brush Options") { ix in
            if let v = includesSize { ix.brushes[id]?.includesSize = v }
            if let v = includesToolSettings { ix.brushes[id]?.includesToolSettings = v }
            if let c = color { ix.brushes[id]?.color = c }
        }
    }

    /// New preset from settings ("New Brush Preset…"). The tip is shared with whatever the settings use.
    @discardableResult
    func newBrush(from s: BrushSettings, name: String, in folder: String? = nil, includesSize: Bool = true, includesToolSettings: Bool = false,
                  color: RGBA? = nil, source: String = "New brush from settings") -> String {
        let id = "b-" + UUID().uuidString.prefix(8).lowercased()
        let target = folder ?? defaultFolderForNewBrushes()
        let r = BrushRecord(id: id, name: name.isEmpty ? "Brush" : name, tipID: s.tipID, params: BrushParams(s), includesSize: includesSize,
                            includesToolSettings: includesToolSettings, color: color, source: source, created: Date())
        perform("New Brush") { $0.add(r, to: target) }
        return id
    }

    /// Folder new brushes go into when none is chosen: the active preset's folder, else "Custom" (created as needed).
    func defaultFolderForNewBrushes() -> String {
        if let a = activePresetID, let f = index.folderID(ofBrush: a), f != BrushLibraryIndex.rootID { return f }
        if let f = index.root.folders.first(where: { $0.name == "Custom" }) { return f.id }
        return index.createFolder("Custom")
    }

    /// A brush from a tip image (Define Brush). The tip is normalised: gray, square, at most `maxTipSide`.
    @discardableResult
    func defineBrush(tip: PixelBuffer, name: String, in folder: String? = nil, source: String = "Defined from selection") -> String? {
        let t = Self.normalizedTip(tip)
        guard let tipID = addTip(frames: [t]) else { return nil }
        var p = BrushParams(size: Double(min(max(t.width, t.height), 500)), hardness: 1, spacing: 0.25)
        p.pressureSize = false
        let id = "b-" + UUID().uuidString.prefix(8).lowercased()
        let r = BrushRecord(id: id, name: name.isEmpty ? "Sampled Brush" : name, tipID: tipID, params: p, source: source, created: Date())
        let target = folder ?? defaultFolderForNewBrushes()
        perform("Define Brush") { $0.add(r, to: target) }
        return id
    }

    func restoreDefaults() {
        perform("Restore Default Brushes") { ix in
            ix.deletedDefaults = []
            ix.defaultsVersion = 0
            _ = BrushDefaults.install(into: &ix)
        }
    }

    // MARK: - Tips and patterns

    /// Writes tip frames as PNGs and registers a tip record (not an undo step: unreferenced tips are cleaned at launch).
    func addTip(frames: [PixelBuffer], selection: BrushFrameSelection = .incremental, id: String? = nil) -> String? {
        guard !frames.isEmpty else { return nil }
        let tid = id ?? "t-" + UUID().uuidString.prefix(8).lowercased()
        var files: [String] = []
        do {
            try FileManager.default.createDirectory(at: tipsDir, withIntermediateDirectories: true)
            for (i, f) in frames.enumerated() {
                let name = frames.count == 1 ? "\(tid).png" : "\(tid)_\(i).png"
                guard let png = f.pngData() else { continue }
                try png.write(to: tipsDir.appendingPathComponent(name), options: .atomic)
                files.append(name)
            }
        } catch {
            NSLog("ImageCrat: could not save brush tip: \(error)")
            return nil
        }
        guard !files.isEmpty else { return nil }
        index.tips[tid] = BrushTipRecord(id: tid, files: files, selection: selection)
        tipCache[tid] = (frames, selection)
        return tid
    }

    /// Adds a texture pattern (gray or RGBA) and makes it available to brushes and the Patterns panel.
    func addPattern(_ img: PixelBuffer, name: String, preferredID: String?) -> String? {
        var pid = preferredID.flatMap { $0.isEmpty ? nil : "abr-" + $0 } ?? ("p-" + UUID().uuidString.prefix(8).lowercased())
        if index.patterns.contains(where: { $0.id == pid }) { return pid }      // same pattern imported before
        if PatternLibrary.pattern(id: pid, custom: AppModel.shared.customPatterns) != nil { pid = "p-" + UUID().uuidString.prefix(8).lowercased() }
        let file = "\(pid.replacingOccurrences(of: "/", with: "_")).png"
        do {
            try FileManager.default.createDirectory(at: patternsDir, withIntermediateDirectories: true)
            guard let png = img.pngData() else { return nil }
            try png.write(to: patternsDir.appendingPathComponent(file), options: .atomic)
        } catch { return nil }
        index.patterns.append(BrushPatternRecord(id: pid, name: name, file: file))
        registerPattern(id: pid, name: name, image: img)
        return pid
    }

    private func registerPattern(id: String, name: String, image: PixelBuffer) {
        let app = AppModel.shared
        guard !app.customPatterns.contains(where: { $0.id == id }) else { return }
        app.customPatterns.append(PatternDef(id: id, name: name, image: image.format == .rgba ? image : image.toRGBA()))
    }

    /// Gray, square (content centred), at most `maxTipSide` per side.
    static func normalizedTip(_ b: PixelBuffer) -> PixelBuffer {
        var g = b.format == .gray ? b : b.toGray()
        let side0 = max(g.width, g.height)
        if side0 > maxTipSide {
            let s = Double(maxTipSide) / Double(side0)
            let w = max(1, Int(Double(g.width) * s)), h = max(1, Int(Double(g.height) * s))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(g.makeCGImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
                if let img = ctx.makeImage() { g = PixelBuffer(cgImage: img, format: .gray) }
            }
        }
        if g.width == g.height { return g }
        let side = max(g.width, g.height)
        let sq = PixelBuffer(width: side, height: side, format: .gray)
        sq.copyPixels(from: g, at: IPoint(x: (side - g.width) / 2, y: (side - g.height) / 2))
        sq.markDirty()
        return sq
    }

    // MARK: - Import

    struct ImportResult {
        var file: String
        var setName: String
        var added: [String] = []
        var folderID: String?
        var skipped: [String] = []
        var error: String?
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "psd", "psb", "tif", "tiff", "bmp", "gif", "heic", "webp"]

    /// Files ImageCrat imports as brushes (by extension).
    static func isBrushFile(_ url: URL) -> Bool { BrushImport.supportedExtensions.contains(url.pathExtension.lowercased()) }

    /// Parses one file (any supported brush format, or a plain image as a tip). Runs on any thread.
    static func parse(_ url: URL) throws -> ImportedBrushSet {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let name = url.deletingPathExtension().lastPathComponent
        if BrushImport.isPlainImage(data: data, fileName: url.lastPathComponent) || (imageExtensions.contains(url.pathExtension.lowercased()) && url.pathExtension.lowercased() != "kpp" && !isBrushFile(url)) {
            var set = ImportedBrushSet(name: name, format: "Image")
            set.tips["image"] = ImportedTipImage(.encoded(data))
            var p = BrushParams(size: 100, hardness: 1, spacing: 0.25)
            p.pressureSize = false
            set.brushes = [ImportedBrush(name: name, tipKey: "image", params: p)]
            return set
        }
        return try BrushImport.load(data: data, fileName: url.lastPathComponent)
    }

    /// Decodes an imported image to gray coverage (white = paint).
    static func coverage(_ img: BrushImageData) -> PixelBuffer? {
        switch img {
        case .gray(let g): return g.format == .gray ? g : BrushTipImaging.grayCoverage(fromRGBA: g)
        case .encoded(let data):
            guard let rgba = decodeRGBA(data) else { return nil }
            return BrushTipImaging.grayCoverage(fromRGBA: rgba)
        }
    }

    static func decodeRGBA(_ data: Data) -> PixelBuffer? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width > 0, img.height > 0, img.width <= 16384, img.height <= 16384 else { return nil }
        return PixelBuffer(cgImage: img, format: .rgba)
    }

    /// Adds a parsed set: a folder named after the set (inside `parent`), sub-folders for its groups. Tips that are
    /// image data are decoded here. One undo step.
    @discardableResult
    func add(_ set: ImportedBrushSet, into parent: String = BrushLibraryIndex.rootID, makeSetFolder: Bool = true, source: String) -> ImportResult {
        var result = ImportResult(file: source, setName: set.name, skipped: set.skipped)
        // tips
        var tipIDs: [String: String] = [:]
        for (key, t) in set.tips.sorted(by: { $0.key < $1.key }) {
            let frames = t.frames.compactMap { Self.coverage($0) }.map { Self.normalizedTip($0) }
            if frames.isEmpty { continue }
            if let tid = addTip(frames: frames, selection: t.selection) { tipIDs[key] = tid }
        }
        // patterns
        var patternIDs: [String: String] = [:]
        for p in set.patterns {
            let img: PixelBuffer?
            switch p.image {
            case .gray(let g): img = g
            case .encoded(let d): img = Self.decodeRGBA(d)
            }
            if let img, let pid = addPattern(img, name: p.name, preferredID: p.id) { patternIDs[p.id] = pid }
        }
        let patternsByName = Dictionary((PatternDef.builtIn + AppModel.shared.customPatterns).map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        perform(set.brushes.count == 1 ? "Import Brush" : "Import Brushes") { ix in
            var top = parent
            if makeSetFolder {
                top = ix.createFolder(set.name.isEmpty ? "Imported Brushes" : set.name, in: parent)
            }
            result.folderID = top
            for b in set.brushes {
                var tipID = "round"
                if let k = b.tipKey {
                    guard let t = tipIDs[k] else { result.skipped.append("\(b.name): tip image could not be decoded"); continue }
                    tipID = t
                }
                var p = b.params
                p.sanitize()
                if p.dualEnabled { p.dualTipID = tipIDs[p.dualTipID] ?? (BrushTips.textured.contains(p.dualTipID) ? p.dualTipID : "round") }
                if p.textureEnabled {
                    p.texturePatternID = patternIDs[p.texturePatternID]
                        ?? patternsByName[p.texturePatternName.lowercased()]
                        ?? (PatternLibrary.pattern(id: p.texturePatternID, custom: AppModel.shared.customPatterns) != nil ? p.texturePatternID : "canvas")
                }
                let id = "b-" + UUID().uuidString.prefix(8).lowercased()
                let r = BrushRecord(id: id, name: b.name, tipID: tipID, params: p, includesSize: b.includesSize, includesToolSettings: b.includesToolSettings,
                                    color: b.color, source: source, created: Date())
                let fid = b.folderPath.isEmpty ? top : ix.folder(path: b.folderPath, in: top)
                ix.add(r, to: fid)
                result.added.append(id)
            }
        }
        return result
    }

    /// Imports files synchronously (tests, small imports). Images become tips in "Custom" (or `into`).
    func importFiles(_ urls: [URL], into parent: String? = nil, progress: ((Int, Int, String) -> Void)? = nil) -> [ImportResult] {
        var out: [ImportResult] = []
        for (i, url) in urls.enumerated() {
            progress?(i, urls.count, url.lastPathComponent)
            do {
                let set = try Self.parse(url)
                out.append(add(set, url: url, into: parent))
            } catch {
                out.append(ImportResult(file: url.lastPathComponent, setName: url.deletingPathExtension().lastPathComponent,
                                        error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        return out
    }

    private func add(_ set: ImportedBrushSet, url: URL, into parent: String?) -> ImportResult {
        if set.format == "Image" {
            let target = parent ?? defaultFolderForNewBrushes()
            return add(set, into: target, makeSetFolder: false, source: url.lastPathComponent)
        }
        return add(set, into: parent ?? BrushLibraryIndex.rootID, makeSetFolder: true, source: url.lastPathComponent)
    }

    /// One line per file: "Imported 248 brushes into “Kyle's Inkers”; 3 skipped: …".
    func summary(_ results: [ImportResult]) -> String {
        var lines: [String] = []
        for r in results {
            if let e = r.error { lines.append("\(r.file): \(e)"); continue }
            let folder = r.folderID.flatMap { index.folder($0)?.name } ?? r.setName
            var s = "Imported \(r.added.count) brush\(r.added.count == 1 ? "" : "es") into “\(folder)”"
            if !r.skipped.isEmpty {
                let shown = r.skipped.prefix(3).joined(separator: "; ")
                s += "; \(r.skipped.count) skipped: \(shown)\(r.skipped.count > 3 ? "; …" : "")"
            }
            lines.append(s + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Imports in the background (parsing off the main thread), with progress in the Brushes panel and a summary.
    /// Selects the first imported brush.
    func importInBackground(_ urls: [URL], into parent: String? = nil, completion: (([ImportResult]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        importProgress = ImportProgress(done: 0, total: urls.count, current: urls[0].lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            var parsed: [(URL, Result<ImportedBrushSet, Error>)] = []
            for (i, u) in urls.enumerated() {
                DispatchQueue.main.async { self.importProgress = ImportProgress(done: i, total: urls.count, current: u.lastPathComponent) }
                parsed.append((u, Result { try Self.parse(u) }))
            }
            DispatchQueue.main.async {
                var results: [ImportResult] = []
                for (u, r) in parsed {
                    switch r {
                    case .success(let set): results.append(self.add(set, url: u, into: parent))
                    case .failure(let e):
                        results.append(ImportResult(file: u.lastPathComponent, setName: u.deletingPathExtension().lastPathComponent,
                                                    error: (e as? LocalizedError)?.errorDescription ?? e.localizedDescription))
                    }
                }
                self.importProgress = nil
                self.finishImport(results)
                completion?(results)
            }
        }
    }

    private func finishImport(_ results: [ImportResult]) {
        let text = summary(results)
        lastImportSummary = text
        let added = results.flatMap(\.added)
        if let first = added.first { select(first) }
        AppModel.shared.setStatus(text.components(separatedBy: "\n").first ?? text)
        let failed = results.contains { $0.error != nil }
        let big = added.count >= 20 || results.count > 1 || results.contains { !$0.skipped.isEmpty }
        if failed || big {
            let a = NSAlert()
            a.messageText = tr(added.isEmpty ? "No brushes were imported." : "Imported \(added.count) brush\(added.count == 1 ? "" : "es").")
            a.informativeText = tr(text)
            UIBlock.run(a)
        }
    }

    /// Open panel for every importable brush format.
    static func importBrushes() {
        let panel = NSOpenPanel()
        panel.title = tr("Import Brushes")
        panel.message = tr("Photoshop (.abr, .tpl), Procreate (.brush, .brushset), GIMP (.gbr, .gih), Krita (.kpp), ImageCrat (.icbrushes) or an image")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (Array(BrushImport.supportedExtensions) + Array(imageExtensions)).compactMap { UTType(filenameExtension: $0) }
        guard UIBlock.run(panel) == .OK else { return }
        shared.importInBackground(panel.urls)
    }

    /// Kept for callers of the old API.
    static func importFiles(_ urls: [URL]) { shared.importInBackground(urls) }

    // MARK: - Export

    /// The brushes as an import-style set (gray tips, patterns), for the ABR writer and the brush-set archive.
    func exportSet(_ ids: [String], name: String) -> ImportedBrushSet {
        var set = ImportedBrushSet(name: name, format: "ImageCrat")
        func tipImage(_ tipID: String) -> ImportedTipImage? {
            if tipID == "round" { return nil }
            if let fr = tipFrames(tipID) { return ImportedTipImage(frames: fr.buffers.map { .gray($0) }, selection: fr.selection) }
            if let img = BrushTips.texture(tipID) { return ImportedTipImage(.gray(PixelBuffer(cgImage: img, format: .gray))) }
            return nil
        }
        for id in ids {
            guard let r = index.brushes[id] else { continue }
            var p = r.params
            var key: String?
            if let t = tipImage(r.tipID) { set.tips[r.tipID] = t; key = r.tipID }
            if p.dualEnabled && p.dualTipID != "round" {
                if set.tips[p.dualTipID] == nil, let t = tipImage(p.dualTipID) { set.tips[p.dualTipID] = t }
                if set.tips[p.dualTipID] == nil { p.dualTipID = "round" }
            }
            if p.textureEnabled, !set.patterns.contains(where: { $0.id == p.texturePatternID }),
               let pat = PatternLibrary.pattern(id: p.texturePatternID, custom: AppModel.shared.customPatterns) {
                set.patterns.append(ImportedPattern(id: pat.id, name: pat.name, image: .gray(pat.image.toGray())))
                p.texturePatternName = pat.name
            }
            let folder = index.folderID(ofBrush: id).map { index.path(ofFolder: $0) } ?? []
            set.brushes.append(ImportedBrush(name: r.name, folderPath: folder, tipKey: key, params: p, color: r.color,
                                             includesSize: r.includesSize, includesToolSettings: r.includesToolSettings))
        }
        // Folder paths relative to the deepest folder all brushes share.
        if let first = set.brushes.first?.folderPath {
            var common = first
            for b in set.brushes { while !common.isEmpty && Array(b.folderPath.prefix(common.count)) != common { common.removeLast() } }
            for i in set.brushes.indices { set.brushes[i].folderPath = Array(set.brushes[i].folderPath.dropFirst(common.count)) }
        }
        return set
    }

    func abrData(_ ids: [String], name: String) -> (Data, [String]) {
        let r = ABRWriter.write(exportSet(ids, name: name))
        return (r.data, r.notes)
    }

    func brushSetData(_ ids: [String], name: String) -> Data { BrushSetArchive.write(exportSet(ids, name: name)) }

    enum ExportFormat { case abr, imageCrat }

    /// Save panel, then writes the brushes as .abr or .icbrushes.
    func exportWithPanel(_ ids: [String], suggestedName: String, format: ExportFormat) {
        guard !ids.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = tr(format == .abr ? "Export Brushes as Photoshop ABR" : "Export ImageCrat Brushes")
        let ext = format == .abr ? "abr" : "icbrushes"
        if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
        panel.nameFieldStringValue = suggestedName + "." + ext
        guard UIBlock.run(panel) == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .abr:
                let (d, notes) = abrData(ids, name: suggestedName)
                try d.write(to: url, options: .atomic)
                AppModel.shared.setStatus("Exported \(ids.count) brush\(ids.count == 1 ? "" : "es") to \(url.lastPathComponent)\(notes.isEmpty ? "" : " (\(notes.count) note\(notes.count == 1 ? "" : "s"))").")
            case .imageCrat:
                try brushSetData(ids, name: suggestedName).write(to: url, options: .atomic)
                AppModel.shared.setStatus("Exported \(ids.count) brush\(ids.count == 1 ? "" : "es") to \(url.lastPathComponent).")
            }
        } catch {
            let a = NSAlert()
            a.messageText = tr("The brushes could not be exported.")
            a.informativeText = error.localizedDescription
            UIBlock.run(a)
        }
    }

    // MARK: - Thumbnails

    /// Tip thumbnail (white tip on transparent, `size` px square).
    func thumbnail(_ id: String, size: Int = 64, color: RGBA = .white) -> CGImage? {
        guard let r = index.brushes[id] else { return nil }
        let key = "t|\(id)|\(size)|\(color.hex)|\(revision)"
        if let c = thumbCache[key] { return c }
        let p = r.params
        guard let m = BrushTips.mask(diameter: Double(max(4, size - 4)), hardness: p.hardness, roundness: p.roundness, angle: p.angle, tipID: r.tipID),
              let img = BrushTips.colored(m, color: color) else { return nil }
        thumbCache[key] = img
        return img
    }

    /// Photoshop's "Brush Stroke" view: an S-curve with a pressure taper, painted with the preset (`scale` 2 = Retina).
    func strokePreview(_ id: String, width: Int, height: Int, fg: RGBA = RGBA(gray: 0.1), bg: RGBA = RGBA(hex: "4A90E2")!) -> CGImage? {
        guard let r = index.brushes[id] else { return nil }
        let key = "s|\(id)|\(width)x\(height)|\(fg.hex)|\(revision)"
        if let c = thumbCache[key] { return c }
        let img = BrushStrokePreview.render(standaloneSettings(r), width: width, height: height, fg: fg, bg: bg)
        thumbCache[key] = img
        if thumbCache.count > 1500 { thumbCache.removeAll() }
        return img
    }

    // MARK: - Persistence

    private func load(installDefaults: Bool) {
        let fm = FileManager.default
        var ix = BrushLibraryIndex()
        var loaded = false
        if let data = try? Data(contentsOf: indexURL) {
            if let decoded = try? BrushLibraryIndex.decode(data) {
                ix = decoded
                loaded = true
            } else {
                // Keep the damaged file for inspection, start over.
                let bad = directory.appendingPathComponent("library-damaged-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.moveItem(at: indexURL, to: bad)
                NSLog("ImageCrat: the brush library index could not be read; moved to \(bad.lastPathComponent)")
            }
        }
        index = ix
        if !loaded { migrateV1() }
        if let d = try? Data(contentsOf: prefsURL), let p = try? JSONDecoder().decode(Prefs.self, from: d) { prefs = p }
        var installed = 0
        if installDefaults { installed = BrushDefaults.install(into: &index) }
        // Tips no brush uses any more (deleted before the last quit): remove their files.
        for tid in index.unreferencedTips {
            for f in index.tips[tid]?.files ?? [] { try? fm.removeItem(at: tipsDir.appendingPathComponent(f)) }
            index.tips.removeValue(forKey: tid)
        }
        // Patterns for textures.
        for p in index.patterns {
            let url = patternsDir.appendingPathComponent(p.file)
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                registerPattern(id: p.id, name: p.name, image: PixelBuffer(cgImage: img, format: .rgba))
            }
        }
        if installed > 0 || !loaded { saveNow() }
    }

    /// Libraries written before folders existed: `index.json` with a flat list of imported tips.
    private func migrateV1() {
        struct Entry: Codable { var id: String; var name: String; var diameter: Double; var spacing: Double; var file: String }
        let old = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: old), let list = try? JSONDecoder().decode([Entry].self, from: data), !list.isEmpty else { return }
        let fid = index.createFolder("Imported Brushes")
        for e in list {
            let url = directory.appendingPathComponent(e.file)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            // (the old id stays the tip id: saved tool settings refer to it)
            guard let tid = addTip(frames: [PixelBuffer(cgImage: img, format: .gray)], id: e.id) else { continue }
            var p = BrushParams(size: e.diameter, hardness: 1, spacing: e.spacing)
            p.pressureSize = false
            p.sanitize()
            index.add(BrushRecord(id: "b-" + e.id, name: e.name, tipID: tid, params: p, source: "Imported (earlier version)"), to: fid)
        }
        try? FileManager.default.moveItem(at: old, to: directory.appendingPathComponent("index-v1-migrated.json"))
    }

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.saveNow() }
    }

    /// Writes library.json now.
    func saveNow() {
        saveScheduled = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try index.encoded().write(to: indexURL, options: .atomic)
        } catch {
            NSLog("ImageCrat: could not save the brush library: \(error)")
        }
    }

    private func savePrefs() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(prefs).write(to: prefsURL, options: .atomic)
        } catch {}
    }

    // MARK: - Helpers

    static func confirm(_ title: String, _ info: String) -> Bool {
        let a = NSAlert()
        a.messageText = tr(title)
        a.informativeText = tr(info)
        a.addButton(withTitle: tr("Delete"))
        a.addButton(withTitle: tr("Cancel"))
        return UIBlock.run(a) == .alertFirstButtonReturn
    }
}
