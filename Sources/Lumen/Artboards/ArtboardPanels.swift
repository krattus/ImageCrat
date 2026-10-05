import AppKit
import SwiftUI
import ImageCratCore

// MARK: - The artboard menu (Layers panel right-click, canvas right-click, Layer ▸ Artboards)

enum ArtboardMenu {
    indirect enum Item {
        case action(String, enabled: Bool = true, checked: Bool? = nil, () -> Void)
        case divider
        case submenu(String, [Item])

        var title: String? {
            switch self {
            case .action(let t, _, _, _), .submenu(let t, _): return t
            case .divider: return nil
            }
        }
    }

    /// The artboards a command on `id` applies to: the selected artboards when `id` is one of them, else `id`.
    static func targets(_ d: Document, _ id: UUID) -> [UUID] {
        let sel = ArtboardOps.selectedBoards(d)
        return sel.contains(id) ? sel : [id]
    }

    static func backgroundItems(_ d: Document, _ ids: [UUID]) -> [Item] {
        let bg = ids.first.flatMap { d.state.layer($0)?.artboard }?.background
        let isWhite = bg == .white, isBlack = bg == .black, isClear = bg == nil
        return [
            .action("White", checked: isWhite) { ArtboardOps.setBackground(d, ids, .white) },
            .action("Black", checked: isBlack) { ArtboardOps.setBackground(d, ids, .black) },
            .action("Transparent", checked: isClear) { ArtboardOps.setBackground(d, ids, nil) },
            .action("Other…", checked: !isWhite && !isBlack && !isClear) { d.selectedLayerIDs = Set(ids); d.activeLayerID = ids.last; DialogRegistry.show("artboardBackground") },
        ]
    }

    /// Items for artboard `id`. `rename` starts renaming in place (the panel row or the canvas name).
    static func items(_ d: Document, _ id: UUID, rename: @escaping () -> Void) -> [Item] {
        let ids = targets(d, id)
        let n = ids.count
        let sel = d.withoutDescendants(d.orderedSelection)
        let groupSelected = sel.count == 1 && (d.state.layer(sel[0]).map { $0.isGroup && !$0.isArtboard } ?? false)
        let layersSelected = !sel.isEmpty && sel.contains { !(d.state.layer($0)?.isArtboard ?? true) }
        return [
            .action(n > 1 ? "Duplicate \(n) Artboards" : "Duplicate Artboard") { ArtboardOps.duplicate(d, ids) },
            .action("Rename Artboard", enabled: n == 1) { d.selectLayer(id); rename() },
            .action(n > 1 ? "Delete \(n) Artboards" : "Delete Artboard") { ArtboardOps.delete(d, ids, keepContents: false) },
            .action("Delete Artboard Only (Keep Contents)") { ArtboardOps.delete(d, ids, keepContents: true, commitName: "Delete Artboard Only") },
            .divider,
            .action("Artboard from Group", enabled: groupSelected) { if let g = sel.first { ArtboardOps.fromGroup(d, g) } },
            .action("Artboard from Layers…", enabled: layersSelected) { AppActions.artboardFromLayers() },
            .action("Ungroup Artboards") { ArtboardOps.ungroup(d, ids) },
            .action("Convert to Group") { ArtboardActions.convertToGroup(d, ids) },
            .divider,
            .submenu("Background Color", backgroundItems(d, ids)),
            .divider,
            .action("Fit Artboard on Screen") { d.selectLayer(id); ZoomController.run(.fitArtboard) },
            .action(n > 1 ? "Export Artboards As…" : "Export Artboard As…") { ArtboardExport.exportAsPanel(d, ids) },
            .action("Artboards to Files…") { d.selectedLayerIDs = Set(ids); DialogRegistry.show("artboardsToFiles") },
            .action("Artboards to PDF…") { ArtboardExport.pdfPanel(d) },
        ]
    }

    /// Layer ▸ New ▸ Artboard: Canvas Size, then one submenu per preset group (Phone, Tablet, Watch, Web, Social,
    /// Paper — as in the options bar's Size menu).
    static func newArtboardItems() -> [Item] {
        [.action("Canvas Size") { AppActions.newArtboard() }, .divider]
            + Artboard.presetGroups.map { g in
                .submenu(g.0, g.1.map { p in .action(Artboard.menuTitle(p.0, p.1)) { AppActions.newArtboard(size: p.1, preset: p.0) } })
            }
    }

    final class Handler: NSObject {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        @objc func run() { f() }
    }

    static func nsMenu(_ items: [Item], title: String = "Artboard") -> NSMenu {
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        for it in items {
            switch it {
            case .divider: m.addItem(.separator())
            case .action(let t, let enabled, let checked, let f):
                let h = Handler(f)
                let mi = NSMenuItem(title: t, action: #selector(Handler.run), keyEquivalent: "")
                mi.target = h
                mi.representedObject = h
                mi.isEnabled = enabled
                if let c = checked { mi.state = c ? .on : .off }
                m.addItem(mi)
            case .submenu(let t, let sub):
                let mi = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                mi.submenu = nsMenu(sub, title: t)
                m.addItem(mi)
            }
        }
        return m
    }

    /// Text rendering of a menu (tests / snapshots).
    static func describe(_ items: [Item], indent: String = "") -> [String] {
        items.flatMap { it -> [String] in
            switch it {
            case .divider: return [indent + "—"]
            case .action(let t, let e, let c, _): return [indent + (c == true ? "✓ " : "  ") + t + (e ? "" : "   (disabled)")]
            case .submenu(let t, let sub): return [indent + "  " + t + " ▸"] + describe(sub, indent: indent + "      ")
            }
        }
    }
}

/// SwiftUI rendering of `ArtboardMenu` items (context menus).
struct ArtboardMenuItems: View {
    let items: [ArtboardMenu.Item]
    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, it in
            switch it {
            case .divider: Divider()
            case .action(let t, let enabled, let checked, let f):
                if let c = checked {
                    Toggle(t, isOn: Binding(get: { c }, set: { _ in f() })).disabled(!enabled)
                } else {
                    Button(t, action: f).disabled(!enabled)
                }
            case .submenu(let t, let sub):
                Menu(t) { AnyView(ArtboardMenuItems(items: sub)) }
            }
        }
    }
}

/// Artboard items in an ordinary layer's context menu.
struct ArtboardLayerMenuItems: View {
    @Bindable var doc: Document
    let layer: Layer
    var body: some View {
        if layer.isGroup && !layer.isArtboard {
            Button("Artboard from Group") { ArtboardOps.fromGroup(doc, layer.id) }
        }
        Button("Artboard from Layers…") { if !doc.selectedLayerIDs.contains(layer.id) { doc.selectLayer(layer.id) }; AppActions.artboardFromLayers() }
    }
}

// MARK: - Layers panel row

/// An artboard in the Layers panel: a top-level header row (no thumbnail, no blending), its size on the right,
/// and the artboard menu on right-click.
struct ArtboardLayerRow: View {
    @Bindable var doc: Document
    let layer: Layer
    @Binding var renaming: UUID?
    @Binding var dropTarget: (UUID, Int)?
    @State private var nameText = ""
    @State private var hover = false
    static let height: CGFloat = 30

    var selected: Bool { doc.selectedLayerIDs.contains(layer.id) }
    var isActive: Bool { doc.activeLayerID == layer.id }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                EyeVisibility.press(doc, .layer(layer.id))   // (clicks / drags on the eye column: UI/Panels/LayersPanelEyeDrag.swift)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? Theme.text : Theme.textFaint)
                    .frame(width: 22, height: Self.height)
            }.buttonStyle(.plain)
            .accessibilityLabel((layer.isVisible ? "Hide " : "Show ") + layer.name)
            Rectangle().fill(Theme.border).frame(width: 1)
            Button {
                doc.updateLayer(layer.id) { $0.isExpanded.toggle() }
            } label: {
                Image(systemName: layer.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textDim).frame(width: 12)
            }.buttonStyle(.plain)
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 12)).foregroundStyle(Theme.text).frame(width: 18)
            nameView
            Spacer(minLength: 2)
            if let r = layer.artboard?.rect {
                Text("\(Int(r.width)) × \(Int(r.height))").font(Theme.fontSmall).monospacedDigit().foregroundStyle(Theme.textFaint)
            }
            if let c = layer.colorLabel.rgba { Circle().fill(Color(nsColor: c.nsColor)).frame(width: 7, height: 7) }
            if layer.locks.anyLocked {
                Image(systemName: layer.locks.all ? "lock.fill" : "lock").font(.system(size: 9)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .eyeRow(.layer(layer.id))
        .background(selected ? Theme.selection.opacity(isActive ? 1 : 0.6) : (hover ? Theme.hover.opacity(0.6) : Theme.panelHeader))
        .overlay(dropIndicator, alignment: .top)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(TapGesture(count: 2).onEnded { renaming = layer.id })
        .simultaneousGesture(TapGesture().onEnded { click() })
        .onDrag { NSItemProvider(object: layer.id.uuidString as NSString) }
        .onDrop(of: [.text], delegate: LayerDropDelegate(target: layer, doc: doc, dropTarget: $dropTarget))
        .contextMenu { ArtboardMenuItems(items: ArtboardMenu.items(doc, layer.id, rename: { renaming = layer.id })) }
        .help("Artboard “\(layer.name)” — double-click to rename, right-click for artboard commands")
    }

    @ViewBuilder var dropIndicator: some View {
        if let (id, pos) = dropTarget, id == layer.id {
            if pos == 1 {
                RoundedRectangle(cornerRadius: 2).stroke(Theme.accent, lineWidth: 2).frame(height: Self.height)
            } else {
                Rectangle().fill(Theme.accent).frame(height: 2).offset(y: pos == 0 ? 0 : Self.height - 2)
            }
        }
    }

    @ViewBuilder var nameView: some View {
        if renaming == layer.id {
            TextField("", text: $nameText)
                .textFieldStyle(.plain)
                .font(Theme.fontBold)
                .padding(2)
                .background(Theme.fieldBG)
                .onSubmit { finishRename() }
                .onAppear { nameText = layer.name }
                .onExitCommand { renaming = nil }
        } else {
            Text(layer.name)
                .font(Theme.fontBold)
                .foregroundStyle(layer.isVisible ? Theme.text : Theme.textDim)
                .lineLimit(1)
        }
    }

    func click() {
        let f = NSEvent.modifierFlags
        doc.selectLayer(layer.id, extend: f.contains(.command), range: f.contains(.shift))
        doc.editTarget = .content
    }

    func finishRename() {
        ArtboardOps.rename(doc, layer.id, nameText)
        renaming = nil
    }
}

// MARK: - Properties panel

/// Properties of the selected artboard: size, position, preset, orientation and background.
struct ArtboardProperties: View {
    @Bindable var doc: Document
    let layerID: UUID
    let ab: Artboard

    func resize(_ w: CGFloat, _ h: CGFloat, preset: String? = nil) {
        let r = CGRect(x: ab.rect.minX, y: ab.rect.minY, width: min(max(1, w.rounded()), CGFloat(maxCanvasDimension)), height: min(max(1, h.rounded()), CGFloat(maxCanvasDimension)))
        guard r != ab.rect || preset != ab.presetName else { return }
        ArtboardOps.setRect(doc, layerID, r, preset: preset)
    }

    var body: some View {
        Caption("Artboard")
        WrappingHStack {
            NumberField(label: "W", value: Binding(get: { Double(ab.rect.width) }, set: { v in resize(CGFloat(v), ab.rect.height) }), width: 56)
            NumberField(label: "H", value: Binding(get: { Double(ab.rect.height) }, set: { v in resize(ab.rect.width, CGFloat(v)) }), width: 56)
            IconButton(symbol: "rectangle.portrait", help: "Portrait", active: ab.rect.height >= ab.rect.width) {
                if ab.rect.width > ab.rect.height { resize(ab.rect.height, ab.rect.width, preset: ab.presetName) }
            }
            IconButton(symbol: "rectangle", help: "Landscape", active: ab.rect.width > ab.rect.height) {
                if ab.rect.height > ab.rect.width { resize(ab.rect.height, ab.rect.width, preset: ab.presetName) }
            }
        }
        // position in the document's own coordinates: they don't change when Auto-size Canvas moves the canvas corner
        let pos = ArtboardCoords.artboardPosition(ab.rect, doc.state)
        WrappingHStack {
            NumberField(label: "X", value: Binding(get: { Double(pos.x) }, set: { v in
                ArtboardOps.move(doc, layerID, to: ArtboardCoords.documentPoint(artboardPosition: CGPoint(x: CGFloat(v), y: pos.y), doc.state))
            }), width: 56)
            NumberField(label: "Y", value: Binding(get: { Double(pos.y) }, set: { v in
                ArtboardOps.move(doc, layerID, to: ArtboardCoords.documentPoint(artboardPosition: CGPoint(x: pos.x, y: CGFloat(v)), doc.state))
            }), width: 56)
        }
        WrappingHStack {
            Text("Size").foregroundStyle(Theme.textDim)
            ArtboardPresetMenu(title: ab.presetName ?? "Custom") { name, size in
                let portrait = ab.rect.height >= ab.rect.width
                let s = (portrait == (size.height >= size.width)) ? size : CGSize(width: size.height, height: size.width)
                resize(s.width, s.height, preset: name)
            }
        }
        WrappingHStack {
            Text("Background").foregroundStyle(Theme.textDim)
            Picker("", selection: Binding(get: { ab.background == nil ? 2 : (ab.background == .white ? 0 : (ab.background == .black ? 1 : 3)) }, set: { v in
                ArtboardOps.setBackground(doc, [layerID], v == 0 ? .white : v == 1 ? .black : v == 2 ? nil : (ab.background.flatMap { $0 == .white || $0 == .black ? nil : $0 } ?? RGBA(gray: 0.5)))
            })) {
                Text("White").tag(0); Text("Black").tag(1); Text("Transparent").tag(2); Text("Other").tag(3)
            }.labelsHidden().frame(width: 110)
            if let bg = ab.background, bg != .white, bg != .black {
                ColorWell(color: Binding(get: { bg }, set: { c in ArtboardOps.setBackground(doc, [layerID], c, commit: false) }), onCommit: { doc.commit("Artboard Background") })
            }
        }
        WrappingHStack {
            Button("Duplicate") { ArtboardOps.duplicate(doc, [layerID]) }.buttonStyle(PanelButtonStyle())
            Button("Export As…") { ArtboardExport.exportAsPanel(doc, [layerID]) }.buttonStyle(PanelButtonStyle())
        }
        WrappingHStack {
            Button("Fit on Screen") { doc.selectLayer(layerID); ZoomController.run(.fitArtboard) }.buttonStyle(PanelButtonStyle())
            Button("Fit Canvas") { ArtboardActions.fitCanvas(doc) }.buttonStyle(PanelButtonStyle()).help("Trim the canvas to the artboards")
        }
    }
}

/// The grouped preset list (Phone, Tablet, Watch, Web, Social, Paper).
struct ArtboardPresetMenu: View {
    var title = "Size"
    let pick: (String, CGSize) -> Void
    var body: some View {
        Menu {
            ForEach(Artboard.presetGroups, id: \.0) { g in
                Section(g.0) {
                    ForEach(g.1, id: \.0) { p in Button(Artboard.menuTitle(p.0, p.1)) { pick(p.0, p.1) } }
                }
            }
        } label: { Text(title).lineLimit(1) }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

// MARK: - Artboard tool options bar

struct ArtboardOptions: View {
    @Bindable var app = AppModel.shared
    @State private var spacing: Double = 100
    var body: some View {
        let _ = app.sessionTick
        let d = app.activeDocument
        let ab = d.flatMap { ArtboardTool.activeArtboard($0) }
        ArtboardPresetMenu(title: ab?.artboard?.presetName ?? "Size") { name, size in
            guard let d else { return }
            guard let a = ab, let r = a.artboard?.rect else { AppActions.newArtboard(size: size, preset: name); return }
            ArtboardOps.setRect(d, a.id, CGRect(origin: r.origin, size: size), preset: name)
        }
        if let d, let a = ab, let r = a.artboard?.rect {
            NumberField(label: "W", value: Binding(get: { Double(r.width) }, set: { v in
                ArtboardOps.setRect(d, a.id, CGRect(x: r.minX, y: r.minY, width: min(max(1, v), Double(maxCanvasDimension)), height: r.height))
            }), width: 50)
            NumberField(label: "H", value: Binding(get: { Double(r.height) }, set: { v in
                ArtboardOps.setRect(d, a.id, CGRect(x: r.minX, y: r.minY, width: r.width, height: min(max(1, v), Double(maxCanvasDimension))))
            }), width: 50)
            IconButton(symbol: "rectangle.portrait", help: "Portrait", active: r.height >= r.width) {
                if r.width > r.height { ArtboardOps.setRect(d, a.id, CGRect(x: r.minX, y: r.minY, width: r.height, height: r.width), preset: a.artboard?.presetName) }
            }
            IconButton(symbol: "rectangle", help: "Landscape", active: r.width > r.height) {
                if r.height > r.width { ArtboardOps.setRect(d, a.id, CGRect(x: r.minX, y: r.minY, width: r.height, height: r.width), preset: a.artboard?.presetName) }
            }
        }
        ArtboardSettingsMenu()   // gear: Auto-size Canvas, Auto-nest Layers, Show Artboard Names
        Button("Add New Artboard") {
            guard let d else { return }
            if let a = ab { ArtboardTool.addAdjacent(d, to: a.id, side: .right) } else { AppActions.newArtboard() }
        }.buttonStyle(PanelButtonStyle())
        if let d, ArtboardOps.selectedBoards(d).count > 1 {
            let ids = ArtboardOps.selectedBoards(d)
            HStack(spacing: 1) {
                IconButton(symbol: "align.horizontal.left", help: "Align left edges") { ArtboardOps.align(d, ids, .left) }
                IconButton(symbol: "align.horizontal.center", help: "Align horizontal centers") { ArtboardOps.align(d, ids, .centerX) }
                IconButton(symbol: "align.horizontal.right", help: "Align right edges") { ArtboardOps.align(d, ids, .right) }
                IconButton(symbol: "align.vertical.top", help: "Align top edges") { ArtboardOps.align(d, ids, .top) }
                IconButton(symbol: "align.vertical.center", help: "Align vertical centers") { ArtboardOps.align(d, ids, .centerY) }
                IconButton(symbol: "align.vertical.bottom", help: "Align bottom edges") { ArtboardOps.align(d, ids, .bottom) }
            }
            NumberField(label: "Spacing", value: $spacing, width: 44)
            IconButton(symbol: "distribute.horizontal.left", help: "Lay out in a row with this spacing") { ArtboardOps.distribute(d, ids, horizontal: true, spacing: CGFloat(spacing)) }
            IconButton(symbol: "distribute.vertical.top", help: "Lay out in a column with this spacing") { ArtboardOps.distribute(d, ids, horizontal: false, spacing: CGFloat(spacing)) }
        }
        Text("Drag to create · drag a name to move · + adds beside (⌥ duplicates)").foregroundStyle(Theme.textFaint).lineLimit(1)
    }
}

// MARK: - Small dialogs

struct ArtboardBackgroundDialog: View {
    /// Wide enough for the colour picker's full layout (square, hue strip and the value column) plus the frame's margins.
    static let width: CGFloat = 380
    @State private var color = RGBA(gray: 0.5)
    var body: some View {
        DialogFrame(title: "Artboard Background Color", width: Self.width, onOK: {
            guard let d = AppActions.doc else { return }
            ArtboardOps.setBackground(d, ArtboardOps.selectedBoards(d), color)
        }) {
            ColorPickerView(color: $color, showAlpha: false)
        }
        .onAppear {
            if let d = AppActions.doc, let id = ArtboardOps.selectedBoards(d).first, let bg = d.state.layer(id)?.artboard?.background { color = bg }
        }
    }
}

struct ArtboardRenameDialog: View {
    @State private var name = ""
    var body: some View {
        DialogFrame(title: "Rename Artboard", width: 300, okTitle: "Rename", onOK: {
            guard let d = AppActions.doc, let id = ArtboardOps.selectedBoards(d).first else { return }
            ArtboardOps.rename(d, id, name)
        }) {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
        }
        .onAppear {
            if let d = AppActions.doc, let id = ArtboardOps.selectedBoards(d).first { name = d.state.layer(id)?.name ?? "" }
        }
    }
}

// MARK: - App-level actions (menus)

enum ArtboardActions {
    static func convertToGroup(_ d: Document, _ ids: [UUID]) {
        let boards = ids.filter { d.state.layer($0)?.isArtboard == true }
        guard !boards.isEmpty else { Beep.play(); return }
        for id in boards {
            d.updateLayer(id) { l in
                guard case .group(var g) = l.content else { return }
                g.artboard = nil
                l.content = .group(g)
                l.blendMode = .passThrough
            }
        }
        d.commit("Convert to Group")
        Compositor.shared.clearCaches()
    }

    static func fitCanvas(_ d: Document) {
        let w = d.state.width, h = d.state.height, o = ArtboardOps.union(d.state)?.origin
        ArtboardOps.fitCanvas(d)
        if d.state.width != w || d.state.height != h || ArtboardOps.union(d.state)?.origin != o {
            d.commit("Fit Canvas to Artboards")
            Compositor.shared.clearCaches()
        } else {
            AppModel.shared.setStatus("The canvas already fits the artboards.")
        }
    }

    /// Layer ▸ New ▸ Artboard: a new document gets an artboard covering the canvas (with the layers); later ones go
    /// beside the existing artboards.
    static func newArtboard(_ d: Document, size: CGSize?, preset: String? = nil) {
        let existing = ArtboardOps.boards(d.state)
        if let last = existing.compactMap({ $0.artboard?.rect }).max(by: { $0.maxX < $1.maxX }) {
            let s = size ?? last.size
            let r = ArtboardOps.freeRect(d.state, size: s, beside: last, side: .right)
            ArtboardOps.create(d, rect: r, preset: preset)
        } else {
            let s = size ?? CGSize(width: d.state.width, height: d.state.height)
            ArtboardOps.create(d, rect: CGRect(origin: .zero, size: s), preset: preset)
        }
    }

    /// File ▸ New with "Artboards": one artboard the size of the document, holding an empty layer, filled with the
    /// chosen background (no Background layer).
    static func newDocument(width w: Int, height h: Int, resolution: Double, background: RGBA?, name: String) -> Document {
        var st = DocumentState(width: w, height: h, resolution: validResolution(resolution))
        st.layers = [ArtboardOps.makeLayer("Artboard 1", rect: CGRect(x: 0, y: 0, width: w, height: h), background: background,
                                           children: [Layer.raster(name: "Layer 1", width: w, height: h)])]
        let d = Document(state: st, name: name)
        d.activeLayerID = st.layers[0].children.first?.id
        d.selectedLayerIDs = d.activeLayerID.map { [$0] } ?? []
        return d
    }
}
