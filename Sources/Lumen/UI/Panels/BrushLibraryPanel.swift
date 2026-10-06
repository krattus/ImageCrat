import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Brushes panel / brush preset picker
//
// The brush library browser: search, folder filter, Favourites and Recent, the folder tree (collapsible, drag to
// reorder and move, drop brush files to import), three views (tip thumbnails, Photoshop's "Brush Stroke" previews, a
// list) with a size slider, and context menus. Used as the Brushes panel and, compact, in the options bar's Brush
// Preset picker. Choosing a brush applies it to the current tool right away.

struct BrushLibraryBrowser: View {
    /// Compact: the options-bar pop-over (fixed height, fewer controls).
    var compact = false
    /// Where a chosen preset goes (nil: the current tool's settings).
    var onChoose: ((String) -> Void)? = nil

    @Bindable var lib = BrushLibrary.shared
    @Bindable var app = AppModel.shared
    @State private var query = ""
    @State private var folderFilter: String? = nil
    @State private var selection: Set<String> = []
    @State private var dropFolder: String? = nil
    @Environment(\.panelWidth) private var panelWidth

    private var light: Bool { app.prefs.theme.isLight }
    private var ink: RGBA { light ? RGBA(gray: 0.12) : RGBA(gray: 0.88) }
    private var thumb: CGFloat { CGFloat(lib.prefs.thumbSize) }
    private var filtering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || folderFilter != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toolbar
            if let p = lib.importProgress {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total))).controlSize(.small)
                    Text("Importing \(p.current)… (\(p.done + 1) of \(p.total))").font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filtering {
                        let ids = lib.index.search(query, inFolder: folderFilter)
                        if ids.isEmpty {
                            Text("No brushes match.").font(Theme.font).foregroundStyle(Theme.textFaint).padding(.vertical, 8)
                        } else {
                            brushes(ids, folder: nil)
                        }
                    } else {
                        if !lib.index.favorites.isEmpty {
                            special("Favorites", symbol: "star.fill", ids: lib.index.favorites, collapsed: \.favoritesCollapsed)
                        }
                        if !lib.index.recent.isEmpty {
                            special("Recent", symbol: "clock", ids: lib.index.recent, collapsed: \.recentCollapsed)
                        }
                        ForEach(lib.index.root.folders) { f in folderSection(f, depth: 0) }
                        if !lib.index.root.brushes.isEmpty { brushes(lib.index.root.brushes, folder: BrushLibraryIndex.rootID) }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: compact ? 260 : nil)
            .frame(maxHeight: compact ? nil : .infinity)
            .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in drop(providers, folder: BrushLibraryIndex.rootID, before: nil) }
            if !compact { bottomBar }
        }
        .font(Theme.font)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                TextField("Search Brushes", text: $query).textFieldStyle(.plain).frame(minWidth: 40)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint) }.buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, 5).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            folderMenu
            viewMenu
        }
    }

    private var folderMenu: some View {
        Menu {
            Button("All Folders") { folderFilter = nil }
            Divider()
            ForEach(lib.index.allFolders, id: \.id) { f in
                Button(tr((folderFilter == f.id ? "✓ " : "") + String(repeating: "   ", count: f.path.count - 1) + (f.path.last ?? ""))) { folderFilter = f.id }
            }
        } label: {
            Image(systemName: folderFilter == nil ? "folder" : "folder.fill")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(tr(folderFilter.flatMap { lib.index.folder($0)?.name }.map { "Showing “\($0)”" } ?? "Filter by folder"))
    }

    private var viewMenu: some View {
        Menu {
            Picker("View", selection: $lib.prefs.viewMode) {
                Text("Brush Tips").tag(BrushLibrary.Prefs.ViewMode.tips)
                Text("Brush Strokes").tag(BrushLibrary.Prefs.ViewMode.strokes)
                Text("List").tag(BrushLibrary.Prefs.ViewMode.list)
            }.pickerStyle(.inline)
            Divider()
            Button("New Brush Preset…") { DefineBrush.newBrushFromCurrentSettings() }
            Button("New Folder") { _ = lib.createFolder("New Folder", in: folderFilter ?? BrushLibraryIndex.rootID) }
            Button("Define Brush from Selection…") { AppActions.defineBrush() }.disabled(app.activeDocument == nil)
            Button("Define Brush from Layer…") { DefineBrush.run(.activeLayer) }.disabled(app.activeDocument?.activeLayer == nil)
            Divider()
            Button("Import Brushes…") { BrushLibrary.importBrushes() }
            Menu("Export All") {
                Button("As Photoshop Brushes (.abr)…") { lib.exportWithPanel(lib.index.orderedBrushIDs, suggestedName: "ImageCrat Brushes", format: .abr) }
                Button("As ImageCrat Brushes (.icbrushes)…") { lib.exportWithPanel(lib.index.orderedBrushIDs, suggestedName: "ImageCrat Brushes", format: .imageCrat) }
            }
            Divider()
            Button(tr(lib.undoName.map { "Undo \($0)" } ?? "Undo")) { lib.undo() }.disabled(lib.undoName == nil)
            Button(tr(lib.redoName.map { "Redo \($0)" } ?? "Redo")) { lib.redo() }.disabled(lib.redoName == nil)
            Divider()
            Toggle("Keep Current Size When Switching", isOn: $lib.prefs.keepSize)
            Toggle("Apply Preset Colors", isOn: $lib.prefs.applyColor)
            Divider()
            Button("Restore Default Brushes") { lib.restoreDefaults() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("View and brush library commands")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        WrappingHStack(spacing: 4) {
            Slider(value: $lib.prefs.thumbSize, in: 28...96).controlSize(.mini).frame(minWidth: 60, maxWidth: 140)
                .help("Thumbnail size")
            Spacer(minLength: 0)
            IconButton(symbol: "folder.badge.plus", help: "New folder") { _ = lib.createFolder("New Folder", in: folderFilter ?? BrushLibraryIndex.rootID) }
            IconButton(symbol: "plus.square", help: "New brush from the current settings") { DefineBrush.newBrushFromCurrentSettings() }
            IconButton(symbol: "square.and.arrow.down", help: "Import brushes (.abr, .tpl, .brush, .brushset, .gbr, .gih, .kpp, .icbrushes, images)") { BrushLibrary.importBrushes() }
            IconButton(symbol: "trash", help: "Delete the selected brushes") {
                let ids = selection.isEmpty ? (lib.activePresetID.map { [$0] } ?? []) : Array(selection)
                lib.delete(lib.index.orderedBrushIDs.filter { ids.contains($0) })
                selection = []
            }
        }
    }

    // MARK: Sections

    private func special(_ title: String, symbol: String, ids: [String], collapsed: WritableKeyPath<BrushLibrary.Prefs, Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: lib.prefs[keyPath: collapsed] ? "chevron.right" : "chevron.down").font(.system(size: 8)).frame(width: 10)
                Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(title == "Favorites" ? Color.yellow : Theme.textDim)
                Text(tr(title)).font(Theme.fontBold).foregroundStyle(Theme.textDim)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { lib.prefs[keyPath: collapsed].toggle() }
            if !lib.prefs[keyPath: collapsed] { brushes(ids, folder: nil) }
        }
    }

    private func folderSection(_ f: BrushFolderNode, depth: Int) -> AnyView {
        let count = lib.index.brushIDs(inFolder: f.id).count
        return AnyView(VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: f.expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).frame(width: 10)
                Image(systemName: f.expanded ? "folder" : "folder.fill").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Text(tr(f.name)).font(Theme.fontBold).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(count)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2).padding(.leading, CGFloat(depth) * 10)
            .background(RoundedRectangle(cornerRadius: 3).fill(dropFolder == f.id ? Theme.selection : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { lib.setExpanded(f.id, !f.expanded) }
            .onDrag { NSItemProvider(object: BrushLibrary.dragPayload(folder: f.id) as NSString) }
            .onDrop(of: [.fileURL, .plainText], isTargeted: Binding(get: { dropFolder == f.id }, set: { dropFolder = $0 ? f.id : (dropFolder == f.id ? nil : dropFolder) })) { providers in
                drop(providers, folder: f.id, before: nil)
            }
            .contextMenu { folderMenu(f) }
            .help(tr("\(tr(f.name)): \(count) brush\(count == 1 ? "" : "es") — drag brushes or folders here, or drop brush files to import into it"))
            if f.expanded {
                ForEach(f.folders) { s in folderSection(s, depth: depth + 1) }
                if !f.brushes.isEmpty { brushes(f.brushes, folder: f.id).padding(.leading, CGFloat(depth) * 10 + 6) }
            }
        })
    }

    @ViewBuilder
    private func brushes(_ ids: [String], folder: String?) -> some View {
        switch lib.prefs.viewMode {
        case .tips:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumb, maximum: thumb), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(ids, id: \.self) { id in cell(id, folder: folder) }
            }
        case .strokes, .list:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ids, id: \.self) { id in row(id, folder: folder) }
            }
        }
    }

    private func isActive(_ id: String) -> Bool { lib.activePresetID == id }

    private func cell(_ id: String, folder: String?) -> some View {
        let r = lib.record(id)
        return VStack(spacing: 1) {
            ZStack {
                if let img = lib.thumbnail(id, size: Int(thumb * 1.6), color: ink) {
                    Image(decorative: img, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(3)
                }
            }
            .frame(width: thumb, height: thumb * 0.78)
            Text(tr(r.map { "\(Int($0.params.size))" } ?? "")).font(.system(size: 8)).foregroundStyle(Theme.textFaint).lineLimit(1)
        }
        .frame(width: thumb, height: thumb)
        .background(RoundedRectangle(cornerRadius: 4).fill(isActive(id) ? Theme.selection : (selection.contains(id) ? Theme.selection.opacity(0.55) : Theme.fieldBG)))
        .overlay(alignment: .topTrailing) {
            if lib.isFavorite(id) { Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(.yellow).padding(2) }
        }
        .overlay(alignment: .topLeading) {
            if isActive(id) && lib.isActivePresetModified { Text("*").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent).padding(.leading, 3) }
        }
        .contentShape(Rectangle())
        .help(tr(tooltip(id)))
        .modifier(BrushItemInteractions(id: id, folder: folder, browser: self))
    }

    private func row(_ id: String, folder: String?) -> some View {
        let r = lib.record(id)
        let strokes = lib.prefs.viewMode == .strokes
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if !strokes, let img = lib.thumbnail(id, size: 40, color: ink) {
                    Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                }
                Text(tr((r?.name ?? "") + (isActive(id) && lib.isActivePresetModified ? " *" : ""))).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if lib.isFavorite(id) { Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(.yellow) }
                Spacer(minLength: 2)
                Text(tr(r.map { "\(Int($0.params.size))" } ?? "")).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            if strokes {
                GeometryReader { g in
                    if let img = lib.strokePreview(id, width: max(40, Int(g.size.width)), height: max(16, Int(g.size.height)), fg: ink) {
                        Image(decorative: img, scale: 2).frame(width: g.size.width, height: g.size.height)
                    }
                }
                .frame(height: max(22, thumb * 0.7))
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(isActive(id) ? Theme.selection : (selection.contains(id) ? Theme.selection.opacity(0.55) : Color.clear)))
        .contentShape(Rectangle())
        .help(tr(tooltip(id)))
        .modifier(BrushItemInteractions(id: id, folder: folder, browser: self))
    }

    private func tooltip(_ id: String) -> String {
        guard let r = lib.record(id) else { return "" }
        var parts = [r.name, "\(Int(r.params.size)) px"]
        if let f = lib.index.folderID(ofBrush: id), f != BrushLibraryIndex.rootID { parts.append(lib.index.path(ofFolder: f).joined(separator: " ▸ ")) }
        if !r.source.isEmpty && r.source != "ImageCrat" { parts.append(r.source) }
        return parts.joined(separator: " — ")
    }

    // MARK: Actions

    func choose(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            return
        }
        selection = []
        if let f = onChoose { f(id) } else { lib.select(id) }
    }

    func dragIDs(_ id: String) -> [String] {
        selection.contains(id) ? lib.index.orderedBrushIDs.filter { selection.contains($0) } : [id]
    }

    /// Internal moves and file imports. `before`: drop onto a brush inserts in front of it.
    func drop(_ providers: [NSItemProvider], folder: String, before: String?) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { lib.importInBackground([url], into: folder == BrushLibraryIndex.rootID ? nil : folder) }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    guard let s = s as? String else { return }
                    DispatchQueue.main.async { lib.handleDrop(s, folder: folder, before: before) }
                }
            }
        }
        dropFolder = nil
        return handled
    }

    @ViewBuilder
    func brushMenu(_ id: String) -> some View {
        let ids = selection.contains(id) ? lib.index.orderedBrushIDs.filter { selection.contains($0) } : [id]
        let r = lib.record(id)
        Button("Use Brush") { lib.select(id) }
        Button("Rename…") { if let n = BrushLibraryBrowser.ask("Rename Brush", initial: r?.name ?? "") { lib.rename(id, to: n) } }
        Button("Duplicate") { _ = lib.duplicate(id) }
        Button(tr(ids.count > 1 ? "Delete \(ids.count) Brushes…" : "Delete…")) { lib.delete(ids); selection = [] }
        Divider()
        Button(tr(lib.isFavorite(id) ? "Remove from Favorites" : "Add to Favorites")) { for i in ids { lib.setFavorite(i, !lib.isFavorite(id)) } }
        Menu("Move to Folder") {
            Button("Top Level") { lib.move(ids, to: BrushLibraryIndex.rootID) }
            ForEach(lib.index.allFolders, id: \.id) { f in
                Button(f.path.joined(separator: " ▸ ")) { lib.move(ids, to: f.id) }
            }
            Divider()
            Button("New Folder…") {
                if let n = BrushLibraryBrowser.ask("New Folder", initial: "New Folder") { let fid = lib.createFolder(n); lib.move(ids, to: fid) }
            }
        }
        Menu("Export") {
            Button("As Photoshop Brushes (.abr)…") { lib.exportWithPanel(ids, suggestedName: ids.count == 1 ? (r?.name ?? "Brush") : "Brushes", format: .abr) }
            Button("As ImageCrat Brushes (.icbrushes)…") { lib.exportWithPanel(ids, suggestedName: ids.count == 1 ? (r?.name ?? "Brush") : "Brushes", format: .imageCrat) }
        }
        Divider()
        Button("Save Current Settings to This Preset") { lib.saveSettings(app.activeBrushSettings, to: id) }
        Toggle("Preset Sets the Size", isOn: Binding(get: { r?.includesSize ?? true }, set: { lib.setFlags(id, includesSize: $0) }))
        Toggle("Preset Sets Opacity, Flow and Mode", isOn: Binding(get: { r?.includesToolSettings ?? false }, set: { lib.setFlags(id, includesToolSettings: $0) }))
        Toggle("Preset Sets the Color", isOn: Binding(get: { r?.color != nil }, set: { lib.setFlags(id, color: .some($0 ? app.foreground : nil)) }))
    }

    @ViewBuilder
    func folderMenu(_ f: BrushFolderNode) -> some View {
        let ids = lib.index.brushIDs(inFolder: f.id)
        Button("New Folder Inside") { _ = lib.createFolder("New Folder", in: f.id) }
        Button("Rename…") { if let n = BrushLibraryBrowser.ask("Rename Folder", initial: f.name) { lib.renameFolder(f.id, to: n) } }
        Button("Show Only This Folder") { folderFilter = f.id }
        Menu("Export Folder") {
            Button("As Photoshop Brushes (.abr)…") { lib.exportWithPanel(ids, suggestedName: f.name, format: .abr) }.disabled(ids.isEmpty)
            Button("As ImageCrat Brushes (.icbrushes)…") { lib.exportWithPanel(ids, suggestedName: f.name, format: .imageCrat) }.disabled(ids.isEmpty)
        }
        Button("Import Brushes into “\(tr(f.name))”…") {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = (Array(BrushImport.supportedExtensions) + Array(BrushLibrary.imageExtensions)).compactMap { UTType(filenameExtension: $0) }
            if UIBlock.run(panel) == .OK { lib.importInBackground(panel.urls, into: f.id) }
        }
        Divider()
        Button("Delete Folder…") { lib.deleteFolder(f.id) }
    }

    /// One-line text prompt (headless runs take the initial text).
    static func ask(_ title: String, initial: String) -> String? {
        let a = NSAlert()
        a.messageText = tr(title)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: tr("OK")); a.addButton(withTitle: tr("Cancel"))
        a.window.initialFirstResponder = f
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return nil }
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// Click / double-click / drag / drop / context menu of a brush cell or row.
private struct BrushItemInteractions: ViewModifier {
    let id: String
    let folder: String?
    let browser: BrushLibraryBrowser
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: targeted ? 2 : 0))
            .onTapGesture { browser.choose(id) }
            .onDrag { NSItemProvider(object: BrushLibrary.dragPayload(brushes: browser.dragIDs(id)) as NSString) }
            .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
                // Onto a brush in a folder: insert before it (Favourites / Recent / search results: into its folder).
                let lib = BrushLibrary.shared
                let f = folder ?? lib.index.folderID(ofBrush: id) ?? BrushLibraryIndex.rootID
                return browser.drop(providers, folder: f, before: folder == nil ? nil : id)
            }
            .contextMenu { browser.brushMenu(id) }
    }
}

// MARK: - Brushes panel

struct BrushesPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        BrushLibraryBrowser().padding(8)
    }
}

// MARK: - Options bar: Brush Preset picker

/// Photoshop's Brush Preset picker: size and hardness of the current brush, then the library with search.
struct BrushPresetPicker: View {
    @Binding var settings: BrushSettings
    @Bindable var lib = BrushLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ValueSlider(label: "Size", value: $settings.size, range: 1...1000, unit: " px", labelWidth: 64)
            ValueSlider(label: "Hardness", value: Binding(get: { settings.hardness * 100 }, set: { settings.hardness = $0 / 100 }), range: 0...100, unit: "%", labelWidth: 64)
                .opacity(settings.tipID == "round" ? 1 : 0.45)
            WrappingHStack {
                Text("Angle").foregroundStyle(Theme.textDim).frame(width: 64, alignment: .leading)
                AngleDial(angle: $settings.angle).frame(width: 26, height: 26)
                ValueSlider(label: "Round", value: Binding(get: { settings.roundness * 100 }, set: { settings.roundness = max(0.02, $0 / 100) }), range: 2...100, unit: "%", labelWidth: 40)
            }
            Divider()
            BrushLibraryBrowser(compact: true) { id in lib.choose(id, into: &settings) }
            HStack {
                Button("New Brush…") { DefineBrush.newBrushFromCurrentSettings() }.buttonStyle(PanelButtonStyle())
                Spacer()
                Button("Import…") { BrushLibrary.importBrushes() }.buttonStyle(PanelButtonStyle())
            }
        }
        .font(Theme.font)
    }
}

/// The options-bar pop-over (kept under its old name for the tools that show it).
struct BrushSettingsView: View {
    @Binding var settings: BrushSettings
    var body: some View { BrushPresetPicker(settings: $settings) }
}
