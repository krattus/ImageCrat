import AppKit
import SwiftUI
import ImageCratCore

/// Brush library: menus, and the `brushlib` self test — every importer (and damaged files), ABR export → import,
/// Define Brush, the editor's live preview, folders / favourites / recent / search / undo / drag and drop, presets
/// applied to tools, persistence across a relaunch, the default set, and the panels rendered offscreen at narrow and
/// default widths. Libraries live in temporary folders; PNGs go to `<out>/brushlib/`.
/// `LUMEN_SELFTEST_ONLY=brushlib Lumen --selftest <dir>`
enum BrushLibraryModule {
    static func register() {
        MenuRegistry.add("File", "Import Brushes…", dividerBefore: true) { BrushLibrary.importBrushes() }
        MenuRegistry.add("Edit", "Define Brush from Layer…", enabled: { AppActions.doc?.activeLayer != nil }) { DefineBrush.run(.activeLayer) }
        MenuRegistry.add("Edit", "New Brush Preset from Current Settings…") { DefineBrush.newBrushFromCurrentSettings() }
        FeatureModules.selfTests.append(("brushlib", { BrushLibrarySelfTest.run($0) }))
    }
}

enum BrushLibrarySelfTest {
    static var passes = 0, failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = ok ? "" : detail()
        print("\(ok ? "PASS" : "FAIL") brushlib: \(name)\(d.isEmpty ? "" : " — " + d)")
        fflush(stdout)
    }

    static var dir = URL(fileURLWithPath: NSTemporaryDirectory())
    static var tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    static func run(_ out: URL) {
        // Confirmations, name prompts and summaries answer OK without showing a window.
        Automation.withHeadless(.ok) { runAll(out) }
    }

    static func runAll(_ out: URL) {
        passes = 0; failures = 0
        dir = out.appendingPathComponent("brushlibrary", isDirectory: true)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("imagecrat-brushlib-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let app = AppModel.shared
        let saved = (tool: app.tool, brush: app.brush, fg: app.foreground, pencil: app.pencil, docs: app.documents, active: app.activeDocumentID)
        defer {
            app.tool = saved.tool; app.brush = saved.brush; app.foreground = saved.fg; app.pencil = saved.pencil
            app.documents = saved.docs; app.activeDocumentID = saved.active
        }

        storageIsSafe()
        defaults()
        organise()
        presetsOnTools()
        persistence()
        importers()
        corruptInputs()
        abrRoundTrip()
        brushSetRoundTrip()
        defineBrush()
        editorPreview()
        animatedTip()
        fileRouting()
        panels()
        print("brushlib: \(passes) passed, \(failures) failed")
    }

    static func lib(_ name: String, defaults: Bool = true) -> BrushLibrary {
        let d = tmp.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: d)
        return BrushLibrary(directory: d, installDefaults: defaults)
    }

    static func savePNG(_ img: CGImage?, _ name: String) {
        guard let img else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func savePNG(_ b: PixelBuffer, _ name: String) { savePNG(b.makeCGImage(), name) }

    static func gray(_ b: PixelBuffer, _ x: Int, _ y: Int) -> Int { Int(b.data.assumingMemoryBound(to: UInt8.self)[y * b.bytesPerRow + x]) }

    /// Mean of a gray buffer (0...255).
    static func mean(_ b: PixelBuffer) -> Double {
        var t = 0
        for y in 0..<b.height { for x in 0..<b.width { t += gray(b, x, y) } }
        return Double(t) / Double(max(1, b.width * b.height))
    }

    // MARK: - Storage

    static func storageIsSafe() {
        let real = Brand.realSupportFolder.standardizedFileURL.path
        let used = BrushLibrary.defaultDirectory.standardizedFileURL.path
        check(!used.hasPrefix(real), "the shared library of an automated run is not in the real support folder", used)
        check(BrushLibrary.shared.directory.standardizedFileURL.path == used, "BrushLibrary.shared uses Brand.supportFolder/Brushes")
    }

    // MARK: - Default set

    static func defaults() {
        let l = lib("defaults")
        let folders = l.index.root.folders.map(\.name)
        check(Array(folders.prefix(4)) == BrushDefaults.folders, "default folders General, Dry Media, Wet Media, Special Effects", "\(folders)")
        let n = l.orderedBrushes.count
        check(n >= 30, "default set has at least 30 brushes", "\(n)")
        check(l.orderedBrushes.allSatisfy { $0.builtIn }, "defaults are marked built-in")
        var empty: [String] = []
        for r in l.orderedBrushes {
            guard let t = l.thumbnail(r.id, size: 48) else { empty.append(r.name); continue }
            let b = PixelBuffer(cgImage: t, format: .rgba)
            if b.opaqueBounds(threshold: 10) == nil { empty.append(r.name) }
        }
        check(empty.isEmpty, "every default brush has a visible tip thumbnail", empty.joined(separator: ", "))
        // Contact sheet of stroke previews (Photoshop's Brush Stroke view).
        let w = 260, h = 44
        let rows = l.orderedBrushes
        let sheet = PixelBuffer(width: w * 2, height: (rows.count + 1) / 2 * h)
        sheet.context.setFillColor(RGBA(gray: 0.97).cgColor)
        sheet.context.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        var blank: [String] = []
        for (i, r) in rows.enumerated() {
            guard let img = l.strokePreview(r.id, width: w / 2, height: h / 2, fg: RGBA(gray: 0.1)) else { blank.append(r.name); continue }
            let pb = PixelBuffer(cgImage: img, format: .rgba)
            if pb.opaqueBounds(threshold: 8) == nil { blank.append(r.name) }
            sheet.drawImage(img, in: CGRect(x: (i % 2) * w, y: (i / 2) * h, width: w, height: h))
        }
        sheet.markDirty()
        savePNG(sheet, "default_stroke_previews")
        check(blank.isEmpty, "every default brush paints a stroke preview", blank.joined(separator: ", "))
        // A defaults update adds new brushes but not ones the user deleted.
        let some = l.orderedBrushes[0].id
        l.delete([some], confirm: false)
        var ix = l.index
        ix.defaultsVersion = 0
        _ = BrushDefaults.install(into: &ix)
        check(ix.brushes[some] == nil, "a deleted default is not brought back by a defaults update")
        l.restoreDefaults()
        check(l.record(some) != nil, "Restore Default Brushes brings it back")
    }

    // MARK: - Folders, favourites, recent, search, undo, drag and drop

    static func organise() {
        let l = lib("organise")
        let general = l.index.root.folders.first { $0.name == "General" }!.id
        let dry = l.index.root.folders.first { $0.name == "Dry Media" }!.id
        let mine = l.createFolder("Mine")
        let sub = l.createFolder("Inks", in: mine)
        check(l.index.path(ofFolder: sub) == ["Mine", "Inks"], "nested folders")
        let hard = l.index.brushIDs(inFolder: general)[0]
        let soft = l.index.brushIDs(inFolder: general)[4]
        // drag a brush into a folder, then onto another brush (insert before it)
        check(l.handleDrop(BrushLibrary.dragPayload(brushes: [hard]), folder: sub), "drop a brush on a folder moves it")
        check(l.index.folderID(ofBrush: hard) == sub, "moved brush is in the folder")
        check(l.handleDrop(BrushLibrary.dragPayload(brushes: [soft]), folder: sub, before: hard), "drop on a brush inserts before it")
        check(l.index.brushIDs(inFolder: sub) == [soft, hard], "order after drop", "\(l.index.brushIDs(inFolder: sub))")
        check(l.handleDrop(BrushLibrary.dragPayload(folder: sub), folder: dry), "drop a folder on another folder nests it")
        check(l.index.path(ofFolder: sub) == ["Dry Media", "Inks"], "folder moved", "\(l.index.path(ofFolder: sub))")
        check(!l.handleDrop(BrushLibrary.dragPayload(folder: dry), folder: sub), "a folder can't be dropped into its own subfolder")
        check(!l.handleDrop("something else", folder: dry), "foreign payloads are refused")
        // undo / redo
        check(l.undoName == "Move Folder", "undo names the last edit", l.undoName ?? "nil")
        l.undo()
        check(l.index.path(ofFolder: sub) == ["Mine", "Inks"], "undo restores the folder's place")
        l.redo()
        check(l.index.path(ofFolder: sub) == ["Dry Media", "Inks"], "redo moves it again")
        // rename, duplicate, delete with undo
        l.rename(hard, to: "My Hard Round")
        check(l.record(hard)?.name == "My Hard Round", "rename")
        let dup = l.duplicate(hard)
        check(dup.flatMap { l.record($0)?.name } == "My Hard Round copy", "duplicate is named “… copy”")
        check(l.index.brushIDs(inFolder: sub) == [soft, hard, dup ?? ""], "duplicate sits next to the original")
        l.delete([dup!], confirm: true)       // (headless: the confirmation answers Delete)
        check(l.record(dup!) == nil, "delete (after confirmation)")
        l.undo()
        check(l.record(dup!) != nil, "undo brings a deleted brush back")
        let n = l.index.brushIDs(inFolder: dry).count
        l.deleteFolder(sub, confirm: false)
        check(l.index.brushIDs(inFolder: dry).count == n - 3 && l.index.folder(sub) == nil, "delete folder with its brushes")
        l.undo()
        check(l.index.folder(sub) != nil && l.index.brushIDs(inFolder: sub).count == 3, "undo restores the folder and its brushes")
        // favourites, recent, search
        l.setFavorite(soft, true)
        check(l.favoriteBrushes.map(\.id) == [soft], "favourites")
        check(l.isFavorite(soft) && !l.isFavorite(hard), "isFavorite")
        let all = l.index.orderedBrushIDs
        for id in all.prefix(14) { l.select(id) }
        check(l.recentBrushes.count == 10 && l.recentBrushes.first?.id == all[13], "Recent keeps the last 10 used, newest first", "\(l.recentBrushes.count)")
        let s1 = l.index.search("soft round")
        check(!s1.isEmpty && s1.allSatisfy { l.record($0)!.name.lowercased().contains("soft") }, "search by name", "\(s1.compactMap { l.record($0)?.name })")
        let s2 = l.index.search("", inFolder: dry)
        check(s2.count == l.index.brushIDs(inFolder: dry).count && !s2.isEmpty, "filter by folder")
        check(l.index.search("charcoal", inFolder: general).isEmpty, "search inside a folder only finds its brushes")
        // collapse state persists and isn't an undo step
        let undoBefore = l.undoName
        l.setExpanded(general, false)
        check(l.index.folder(general)?.expanded == false && l.undoName == undoBefore, "collapse a folder (not an undo step)")
    }

    // MARK: - Choosing presets

    static func presetsOnTools() {
        let app = AppModel.shared
        let l = lib("tools")
        let general = l.index.root.folders.first { $0.name == "General" }!.id
        app.tool = .brush
        app.brush = BrushSettings()
        app.brush.opacity = 0.4
        let hard100 = l.index.brushIDs(inFolder: general).first { l.record($0)?.name == "Hard Round 100" }!
        l.select(hard100)
        check(app.brush.size == 100 && app.brush.hardness == 1, "selecting a preset applies it to the current tool at once")
        check(app.brush.opacity == 0.4, "a preset without tool settings keeps the tool's opacity")
        check(l.activePresetID == hard100 && !l.isActivePresetModified, "active preset, unmodified")
        app.brush.spacing = 0.5
        check(l.isActivePresetModified, "changing a setting marks the preset as modified")
        l.resetActivePreset()
        check(!l.isActivePresetModified && abs(app.brush.spacing - (l.record(hard100)!.params.spacing)) < 1e-9, "Reset to preset")
        app.brush.spacing = 0.33
        l.saveChangesToActivePreset()
        check(!l.isActivePresetModified && abs(l.record(hard100)!.params.spacing - 0.33) < 1e-9, "Save changes to preset")
        // size / colour / tool settings flags
        app.brush.size = 12
        l.setFlags(hard100, includesSize: false)
        l.select(hard100)
        check(app.brush.size == 12, "a preset that doesn't include its size keeps the current size")
        app.foreground = .black
        let red = RGBA(r: 1, g: 0, b: 0)
        let colored = l.newBrush(from: app.brush, name: "Red Marker", includesSize: true, includesToolSettings: true, color: red)
        app.brush.opacity = 1
        l.select(colored)
        check(app.foreground == red, "a preset that includes a colour sets the foreground colour")
        check(app.brush.opacity == 0.4, "a preset with tool settings sets the opacity it was saved with", "\(app.brush.opacity)")
        app.foreground = .black
        l.prefs.applyColor = false
        l.select(colored)
        check(app.foreground == .black, "“Apply Preset Colors” off leaves the colour alone")
        l.prefs.applyColor = true
        l.prefs.keepSize = true
        app.brush.size = 77
        l.select(colored)
        check(app.brush.size == 77, "“Keep Current Size” keeps the size")
        l.prefs.keepSize = false
        // other tools
        app.tool = .pencil
        let soft = l.index.brushIDs(inFolder: general).first { l.record($0)?.name == "Soft Round 45" }!
        l.select(soft)
        check(app.pencil.size == 45 && app.pencil.hardness == 0, "presets apply to the current painting tool (Pencil)")
        app.tool = .move
        l.select(soft)
        check(app.tool == .brush && app.brush.size == 45, "choosing a preset with a non-painting tool switches to the Brush")
        // protect texture
        app.brush.dynamics.textureEnabled = true; app.brush.dynamics.texturePatternID = "dots"; app.brush.dynamics.protectTexture = true
        l.select(hard100)
        check(app.brush.dynamics.textureEnabled && app.brush.dynamics.texturePatternID == "dots", "Protect Texture keeps the texture across presets")
        // the options-bar picker path (a binding to a tool's settings)
        var retouch = BrushSettings()
        l.choose(soft, into: &retouch)
        check(retouch.size == 45 && retouch.hardness == 0, "choose(into:) for the options-bar picker")
        // the canvas quick picker's path: settings of a given tool, that tool's active preset
        app.tool = .brush
        var eraser = BrushSettings()
        l.choose(soft, into: &retouch)   // (Brush: Soft Round 45)
        l.choose(hard100, into: &eraser, tool: .eraser)
        check(l.activePresetID(for: .eraser) == hard100 && l.activePresetID(for: .brush) == soft && l.recentBrushes.first?.id == hard100,
              "choose(into:tool:) sets that tool's active preset and Recent")
        // every brush tool takes presets (the Selection Brush included, without switching to the Brush)
        let savedSel = ToolsSettings.shared.selectionBrush
        app.tool = .selectionBrush
        l.select(soft)
        check(app.tool == .selectionBrush && ToolsSettings.shared.selectionBrush.size == 45 && l.activePresetID == soft,
              "presets apply to the Selection Brush too")
        ToolsSettings.shared.selectionBrush = savedSel
        app.tool = .brush
        // the colour-jitter Control (Brush Settings ▸ Color Dynamics) is part of a preset
        var cj = BrushSettings()
        cj.dynamics.colorEnabled = true; cj.dynamics.hueJitter = 0.4; cj.dynamics.colorJitterControl = ControlSetting(source: .tilt)
        let cjID = l.newBrush(from: cj, name: "Tilt Hue")
        app.brush = BrushSettings()
        l.select(cjID)
        check(app.brush.dynamics.colorJitterControl.source == .tilt && !l.isActivePresetModified, "a preset keeps the colour-jitter Control")
        let back = try? JSONDecoder().decode(BrushParams.self, from: JSONEncoder().encode(BrushParams(cj)))
        check(back?.colorJitterControl.source == .tilt, "…through the library file")
    }

    // MARK: - Persistence

    static func persistence() {
        let d = tmp.appendingPathComponent("relaunch", isDirectory: true)
        try? FileManager.default.removeItem(at: d)
        var l: BrushLibrary? = BrushLibrary(directory: d)
        let a = l!
        let f = a.createFolder("Session")
        let tip = ABRImporter.renderRound(diameter: 64, hardness: 0.3, roundness: 0.5, angle: 30)
        let id = a.defineBrush(tip: tip, name: "Persisted Tip", in: f)!
        a.setFavorite(id, true)
        a.select(id)
        a.prefs.viewMode = .strokes
        a.prefs.thumbSize = 61
        a.saveNow()
        let before = a.index
        l = nil
        let b = BrushLibrary(directory: d)
        check(b.index == before, "library (folders, brushes, favourites, recent) survives a relaunch")
        check(b.prefs.viewMode == .strokes && b.prefs.thumbSize == 61, "view mode and thumbnail size survive a relaunch")
        if let r = b.record(id), let t = b.tipBuffer(r.tipID) {
            var same = t.width == tip.width && t.height == tip.height
            if same { for y in stride(from: 0, to: t.height, by: 3) { for x in stride(from: 0, to: t.width, by: 3) where gray(t, x, y) != gray(tip, x, y) { same = false } } }
            check(same, "tip pixels survive a relaunch")
        } else { check(false, "tip of the persisted brush loads") }
        // A tip whose brush was deleted is cleaned up at the next launch (not before: undo can still need it).
        let tipFile = b.index.tips[b.record(id)!.tipID]!.files[0]
        b.delete([id], confirm: false)
        b.saveNow()
        check(FileManager.default.fileExists(atPath: b.tipsDir.appendingPathComponent(tipFile).path), "a deleted brush's tip file stays until the next launch")
        let c = BrushLibrary(directory: d)
        check(!FileManager.default.fileExists(atPath: c.tipsDir.appendingPathComponent(tipFile).path), "unused tip files are removed at launch")
        // A damaged library file doesn't stop the app: it is set aside and the defaults come back.
        try? Data("{ not json".utf8).write(to: c.indexURL)
        let e = BrushLibrary(directory: d)
        check(e.orderedBrushes.count >= 30, "a damaged library.json is set aside, defaults reinstalled")
        let damaged = (try? FileManager.default.contentsOfDirectory(atPath: d.path))?.contains { $0.hasPrefix("library-damaged-") } ?? false
        check(damaged, "the damaged file is kept for inspection")
        // Libraries from the earlier flat format (index.json + PNG tips) are migrated into a folder.
        let m = tmp.appendingPathComponent("v1", isDirectory: true)
        try? FileManager.default.removeItem(at: m)
        try? FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try? tip.pngData()?.write(to: m.appendingPathComponent("abr-1234abcd.png"))
        try? Data(#"[{"id":"abr-1234abcd","name":"Old Leaf","diameter":64,"spacing":0.2,"file":"abr-1234abcd.png"}]"#.utf8).write(to: m.appendingPathComponent("index.json"))
        let v = BrushLibrary(directory: m)
        let old = v.orderedBrushes.first { $0.name == "Old Leaf" }
        check(old != nil && old!.tipID == "abr-1234abcd" && v.tipBuffer("abr-1234abcd") != nil, "v1 library migrated (old tip ids keep working)")
    }
}
