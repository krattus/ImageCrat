import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Prompts

enum ComponentPrompts {
    /// Modal one-line text prompt (nil when cancelled or when running headless).
    static func text(_ title: String, info: String = "", initial: String = "", ok: String = "OK") -> String? {
        if FilesModule.headless { return nil }
        let a = NSAlert()
        a.messageText = tr(title)
        a.informativeText = tr(info)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: tr(ok))
        a.addButton(withTitle: tr("Cancel"))
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func image() -> (PixelBuffer, String)? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .image]
        p.prompt = tr("Replace")
        p.message = tr("Choose an image for this instance only")
        guard p.runModal() == .OK, let u = p.url, let (cg, _) = DocumentIO.loadImage(url: u) else { return nil }
        return (PixelBuffer(cgImage: cg), u.lastPathComponent)
    }
}

/// Menu / panel entry points working on the active document.
enum ComponentCommands {
    static var doc: Document? { AppActions.doc }
    static var activeInstance: (Document, Layer, ComponentInstance)? {
        guard let d = doc, let l = d.activeLayer, let i = l.componentInstance else { return nil }
        return (d, l, i)
    }

    static func create() {
        guard let d = doc, !d.orderedSelection.isEmpty else { Beep.play(); return }
        AppActions.canvas?.commitCurrentTool()
        if let id = ComponentActions.createComponent(d) {
            ComponentsPanelState.shared.selected = id
            WorkspaceManager.shared.reveal("components")
            AppModel.shared.setStatus("Created component “\(d.state.components[id]?.name ?? "")”. Double-click the instance to edit the main component.")
        } else { Beep.play() }
    }

    static func editMain() {
        guard let (d, _, i) = activeInstance else { Beep.play(); return }
        ComponentActions.editMain(d, component: i.componentID, variant: i.variantID)
    }

    static func detach() {
        guard let d = doc, ComponentActions.detach(d) > 0 else { Beep.play(); return }
    }

    static func resetAll() { if let (d, l, _) = activeInstance { ComponentActions.resetAll(d, layer: l.id) } }
    static func push() {
        guard let (d, l, i) = activeInstance, !i.overrides.isEmpty else { Beep.play(); return }
        let n = ComponentEngine.usageCount(i.componentID, in: d.state)
        if !FilesModule.headless, n > 1,
           !AppActions.confirm("Push this instance's overrides to the main component?", "All \(n) instances of “\(d.state.components[i.componentID]?.name ?? "")” will change.", ok: "Push") { return }
        ComponentActions.pushOverrides(d, layer: l.id)
    }

    static func selectInstances() {
        if let (d, _, i) = activeInstance { ComponentActions.selectInstances(d, component: i.componentID) }
    }

    static func saveAsVariant() {
        guard let (d, l, i) = activeInstance, !i.overrides.isEmpty else { Beep.play(); return }
        if let name = ComponentPrompts.text("New Variant from Overrides", info: "The instance's current look becomes a named variant of the component.", initial: "Variant", ok: "Create") {
            ComponentActions.saveOverridesAsVariant(d, layer: l.id, name: name)
        }
    }

    static func deleteComponent(_ d: Document, _ id: UUID) {
        guard let m = d.state.components[id] else { return }
        let n = ComponentEngine.usageCount(id, in: d.state)
        let info = n == 0 ? "It is not used in this document." : "It is used by \(n) instance\(n == 1 ? "" : "s"), which will become ordinary smart objects (their look is kept)."
        if FilesModule.headless || AppActions.confirm("Delete the component “\(m.name)”?", info, ok: "Delete") {
            ComponentActions.delete(d, component: id)
        }
    }

    static func saveToLibrary(_ d: Document, _ id: UUID, _ url: URL) {
        do {
            var st = d.state
            let v = try ComponentLibraries.publish(id, from: &st, to: url)
            d.state = st
            d.commit("Save to Library")
            ComponentsPanelState.shared.libraryTick += 1
            AppModel.shared.setStatus("Saved “\(st.components[id]?.name ?? "")” to the library “\(url.deletingPathExtension().lastPathComponent)” (version \(v)).")
        } catch { AppActions.alert("Could not save to the library.", error.localizedDescription) }
    }

    static func newLibrary() -> URL? {
        guard let name = ComponentPrompts.text("New Component Library", info: "Libraries are saved as .iclib files and can be used in any document.", initial: "My Library", ok: "Create") else { return nil }
        let u = try? ComponentLibraries.create(named: name)
        ComponentsPanelState.shared.libraryTick += 1
        return u
    }

    static func updateFromLibrary(_ d: Document, _ id: UUID) {
        var st = d.state
        guard ComponentLibraries.update(id, in: &st) else { Beep.play(); return }
        d.state = st
        d.commit("Update from Library")
    }

    /// Places a library component: copies it into the document's table (when missing) and adds an instance.
    @discardableResult
    static func placeFromLibrary(_ d: Document, library url: URL, component id: UUID, center: CGPoint? = nil) -> UUID? {
        guard let lib = ComponentLibraries.load(url) else { return nil }
        var st = d.state
        guard ComponentLibraries.place(id, from: lib, into: &st) else { return nil }
        d.state = st
        let l = ComponentActions.insertInstance(d, component: id, center: center, commit: false)
        d.commit("Place Library Component")
        return l
    }

    // MARK: Drag to canvas

    static let dragPrefix = "lumen-component:"
    static let libraryDragPrefix = "lumen-library-component:"
    private static var savedDragTypes: [NSPasteboard.PasteboardType]?

    /// The canvas only accepts plain-text drags while one of ours is in flight.
    static func beginCanvasDrag() {
        guard let c = AppActions.canvas else { return }
        if savedDragTypes == nil { savedDragTypes = c.registeredDraggedTypes }
        c.registerForDraggedTypes((savedDragTypes ?? []) + [.string])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { endCanvasDrag() }
    }

    static func endCanvasDrag() {
        guard let c = AppActions.canvas, let t = savedDragTypes else { return }
        c.unregisterDraggedTypes()
        c.registerForDraggedTypes(t)
        savedDragTypes = nil
    }

    /// Hook in `CanvasView.performDragOperation`.
    static func handleCanvasDrop(_ sender: NSDraggingInfo, canvas: CanvasView) -> Bool {
        guard let s = sender.draggingPasteboard.string(forType: .string), let d = canvas.document else { return false }
        let p = canvas.viewToDoc(canvas.convert(sender.draggingLocation, from: nil))
        let ok = handleDrop(string: s, doc: d, at: p)
        if ok { endCanvasDrag() }
        return ok
    }

    /// Drop payloads of this module: a document component, a library component, or a clipboard-history item.
    static func handleDrop(string s: String, doc d: Document, at p: CGPoint) -> Bool {
        if s.hasPrefix(dragPrefix), let id = UUID(uuidString: String(s.dropFirst(dragPrefix.count))) {
            if d.state.components[id] == nil, let m = ComponentRegistry.find(id) {
                var st = d.state
                st.components[id] = m
                ComponentEngine.adoptMissing(&st) { ComponentRegistry.find($0) }
                for dep in ComponentEngine.dependencies(of: [id], table: [id: m]) where st.components[dep] == nil { if let x = ComponentRegistry.find(dep) { st.components[dep] = x } }
                d.state = st
            }
            return ComponentActions.insertInstance(d, component: id, center: p) != nil
        }
        if s.hasPrefix(libraryDragPrefix) {
            let parts = String(s.dropFirst(libraryDragPrefix.count)).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return false }
            return placeFromLibrary(d, library: URL(fileURLWithPath: parts[1]), component: id, center: p) != nil
        }
        if s.hasPrefix(ClipboardHistory.dragPrefix), let id = UUID(uuidString: String(s.dropFirst(ClipboardHistory.dragPrefix.count))) {
            return ClipboardHistory.shared.paste(id, mode: .newLayer, into: d, at: p)
        }
        return false
    }
}

// MARK: - Components panel

@Observable
final class ComponentsPanelState {
    static let shared = ComponentsPanelState()
    var selected: UUID?
    var showLibrary = false
    var libraryURL: URL?
    var librarySelected: UUID?
    var libraryTick = 0
    var renaming: UUID?
}

struct ComponentsPanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var ui = ComponentsPanelState.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $ui.showLibrary) {
                    Text("Document").tag(false)
                    Text("Library").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            if ui.showLibrary {
                ComponentLibraryBrowser(doc: app.activeDocument)
            } else if let d = app.activeDocument {
                DocumentComponentsList(doc: d)
            } else {
                Spacer()
                Text("No document").foregroundStyle(Theme.textFaint)
                Spacer()
            }
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text)
    }
}

struct DocumentComponentsList: View {
    @Bindable var doc: Document
    @Bindable var ui = ComponentsPanelState.shared

    var body: some View {
        let masters = ComponentEngine.sorted(doc.state.components)
        VStack(spacing: 0) {
            if masters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.on.square.dashed").font(.system(size: 22)).foregroundStyle(Theme.textFaint)
                    Text("No components yet").font(Theme.fontBold)
                    Text("Select layers and choose Create Component. Every instance follows the main component, and each can override text, images, colours and visibility.")
                        .font(Theme.fontSmall).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Create Component") { ComponentCommands.create() }.buttonStyle(PanelButtonStyle(prominent: true))
                        .disabled(doc.orderedSelection.isEmpty)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: 8)], spacing: 8) {
                        ForEach(masters) { m in
                            ComponentCell(doc: doc, master: m, selected: ui.selected == m.id)
                        }
                    }
                    .padding(8)
                }
            }
            Divider().background(Theme.divider)
            HStack(spacing: 2) {
                IconButton(symbol: "plus.square.on.square", help: "Create Component from the selected layers (⌥⌘K)") { ComponentCommands.create() }
                IconButton(symbol: "square.and.arrow.down.on.square", help: "Insert an instance of the selected component") {
                    if let id = ui.selected { ComponentActions.insertInstance(doc, component: id) }
                }
                IconButton(symbol: "pencil", help: "Edit Main Component") {
                    if let id = ui.selected { ComponentActions.editMain(doc, component: id, variant: nil) }
                }
                IconButton(symbol: "scope", help: "Select all instances") {
                    if let id = ui.selected { ComponentActions.selectInstances(doc, component: id) }
                }
                Spacer(minLength: 2)
                Text("\(masters.count) component\(masters.count == 1 ? "" : "s")").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    .lineLimit(1).minimumScaleFactor(0.75)
                IconButton(symbol: "trash", help: "Delete the selected component") {
                    if let id = ui.selected { ComponentCommands.deleteComponent(doc, id) }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
    }
}

struct ComponentThumb: View {
    let image: CGImage?
    var height: CGFloat = 60
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.24))
            if let cg = image {
                Image(decorative: cg, scale: 2).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(6)
            } else {
                Image(systemName: "square.dashed").foregroundStyle(Theme.textFaint)
            }
        }
        .frame(height: height)
    }
}

struct ComponentCell: View {
    @Bindable var doc: Document
    let master: ComponentMaster
    let selected: Bool
    @Bindable var ui = ComponentsPanelState.shared
    @State private var nameText = ""

    var body: some View {
        let usage = ComponentEngine.usageCount(master.id, in: doc.state)
        let newer = master.library != nil && ComponentLibraries.newerVersion(of: master) != nil
        VStack(spacing: 4) {
            ComponentThumb(image: ComponentEngine.thumbnail(master, table: doc.state.components, size: 120))
                .overlay(alignment: .topTrailing) {
                    Text("×\(usage)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .foregroundStyle(usage == 0 ? Theme.textFaint : Color.white)
                        .padding(3)
                        .help("\(usage) instance\(usage == 1 ? "" : "s") in this document")
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        if !master.variants.isEmpty {
                            Label("\(master.variants.count + 1)", systemImage: "square.stack.3d.up").labelStyle(.titleAndIcon)
                                .font(.system(size: 8, weight: .semibold)).padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Capsule().fill(Color.black.opacity(0.55))).foregroundStyle(.white)
                                .help("\(master.variants.count + 1) variants")
                        }
                        if newer {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                                .help("A newer version is available in the library “\(master.library?.libraryName ?? "")”")
                        } else if master.library != nil {
                            Image(systemName: "books.vertical.fill").font(.system(size: 8)).foregroundStyle(Theme.textDim)
                                .help("Linked to the library “\(master.library?.libraryName ?? "")”")
                        }
                    }.padding(3)
                }
            if ui.renaming == master.id {
                TextField("", text: $nameText)
                    .textFieldStyle(.plain).font(Theme.fontSmall).multilineTextAlignment(.center)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                    .onSubmit { ComponentActions.rename(doc, component: master.id, to: nameText); ui.renaming = nil }
                    .onAppear { nameText = master.name }
            } else {
                Text(master.name).font(Theme.fontSmall).lineLimit(1).truncationMode(.middle)
                    .onTapGesture(count: 2) { ui.renaming = master.id }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selection : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { ComponentActions.insertInstance(doc, component: master.id) }
        .onTapGesture { ui.selected = master.id; if ui.renaming != master.id { ui.renaming = nil } }
        .onDrag {
            ComponentCommands.beginCanvasDrag()
            return NSItemProvider(object: (ComponentCommands.dragPrefix + master.id.uuidString) as NSString)
        }
        .help("Drag onto the canvas (or double-click) to add an instance")
        .contextMenu { menu(usage: usage, newer: newer) }
    }

    @ViewBuilder func menu(usage: Int, newer: Bool) -> some View {
        Button("Insert Instance") { ComponentActions.insertInstance(doc, component: master.id) }
        Button("Edit Main Component") { ComponentActions.editMain(doc, component: master.id, variant: nil) }
        Menu("Variants") {
            ForEach(Array(master.variantChoices.enumerated()), id: \.offset) { _, v in
                Menu(tr(v.name)) {
                    Button("Insert Instance") { ComponentActions.insertInstance(doc, component: master.id, variant: v.id) }
                    Button("Edit…") { ComponentActions.editMain(doc, component: master.id, variant: v.id) }
                    Button("Rename…") {
                        if let n = ComponentPrompts.text("Rename Variant", initial: v.name, ok: "Rename") { ComponentActions.renameVariant(doc, component: master.id, variant: v.id, to: n) }
                    }
                    if let vid = v.id { Button("Delete") { ComponentActions.deleteVariant(doc, component: master.id, variant: vid) } }
                }
            }
            Divider()
            Button("New Variant…") {
                if let n = ComponentPrompts.text("New Variant", info: "A copy of the default variant that you can edit separately (e.g. Hover, Disabled, Dark).", initial: "Hover", ok: "Create"),
                   let v = ComponentActions.addVariant(doc, component: master.id, name: n) {
                    ComponentActions.editMain(doc, component: master.id, variant: v)
                }
            }
        }
        Divider()
        Button("Rename") { ui.selected = master.id; ui.renaming = master.id }
        Button("Duplicate") { ui.selected = ComponentActions.duplicate(doc, component: master.id) }
        Button("Select All Instances (\(usage))") { ComponentActions.selectInstances(doc, component: master.id) }.disabled(usage == 0)
        Divider()
        Menu("Save to Library") {
            ForEach(ComponentLibraries.list(), id: \.self) { u in
                Button(u.deletingPathExtension().lastPathComponent) { ComponentCommands.saveToLibrary(doc, master.id, u) }
            }
            Divider()
            Button("New Library…") { if let u = ComponentCommands.newLibrary() { ComponentCommands.saveToLibrary(doc, master.id, u) } }
        }
        if newer { Button("Update from Library") { ComponentCommands.updateFromLibrary(doc, master.id) } }
        Divider()
        Button(tr(usage == 0 ? "Delete" : "Delete (used by \(usage))…")) { ComponentCommands.deleteComponent(doc, master.id) }
    }
}

// MARK: Library browser

struct ComponentLibraryBrowser: View {
    let doc: Document?
    @Bindable var ui = ComponentsPanelState.shared

    var body: some View {
        let _ = ui.libraryTick
        let libs = ComponentLibraries.list()
        let current = ui.libraryURL.flatMap { u in libs.first { $0 == u } } ?? libs.first
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(libs, id: \.self) { u in Button(u.deletingPathExtension().lastPathComponent) { ui.libraryURL = u } }
                    if !libs.isEmpty { Divider() }
                    Button("New Library…") { if let u = ComponentCommands.newLibrary() { ui.libraryURL = u } }
                    Button("Reveal Libraries Folder") {
                        ComponentsSupport.ensure(ComponentLibraries.folder)
                        NSWorkspace.shared.activateFileViewerSelecting([ComponentLibraries.folder])
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "books.vertical")
                        Text(tr(current?.deletingPathExtension().lastPathComponent ?? "No libraries")).lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            if let u = current, let lib = ComponentLibraries.load(u) {
                if lib.components.isEmpty {
                    Spacer()
                    Text("This library is empty.\nRight-click a document component ▸ Save to Library.").multilineTextAlignment(.center)
                        .font(Theme.fontSmall).foregroundStyle(Theme.textDim).padding(12)
                    Spacer()
                } else {
                    let table = Dictionary(lib.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: 8)], spacing: 8) {
                            ForEach(lib.components) { m in
                                libraryCell(m, table: table, url: u)
                            }
                        }.padding(8)
                    }
                }
                Divider().background(Theme.divider)
                HStack {
                    Button("Place") { if let d = doc, let id = ui.librarySelected { ComponentCommands.placeFromLibrary(d, library: u, component: id) } }
                        .buttonStyle(PanelButtonStyle()).disabled(doc == nil || ui.librarySelected == nil)
                        .help("Copy the component into this document and add an instance")
                    Spacer()
                    Text("\(lib.components.count) in “\(lib.name)”").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical").font(.system(size: 22)).foregroundStyle(Theme.textFaint)
                    Text("Libraries share components between documents.").font(Theme.fontSmall).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                    Button("New Library…") { if let u = ComponentCommands.newLibrary() { ui.libraryURL = u } }.buttonStyle(PanelButtonStyle())
                }.padding(16)
                Spacer()
            }
        }
    }

    @ViewBuilder func libraryCell(_ m: ComponentMaster, table: [UUID: ComponentMaster], url: URL) -> some View {
        let sel = ui.librarySelected == m.id
        let inDoc = doc?.state.components[m.id]
        VStack(spacing: 4) {
            ComponentThumb(image: ComponentEngine.thumbnail(m, table: table, size: 120))
                .overlay(alignment: .topTrailing) {
                    Text("v\(m.version)").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.55))).foregroundStyle(.white).padding(3)
                }
                .overlay(alignment: .topLeading) {
                    if let d = inDoc {
                        Image(systemName: (d.library?.version ?? 0) < m.version ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle((d.library?.version ?? 0) < m.version ? .orange : .green).padding(3)
                            .help(tr((d.library?.version ?? 0) < m.version ? "This document has an older version" : "Already in this document"))
                    }
                }
            Text(tr(m.name)).font(Theme.fontSmall).lineLimit(1).truncationMode(.middle)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Theme.selection : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(sel ? Theme.accent : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let d = doc { ComponentCommands.placeFromLibrary(d, library: url, component: m.id) } }
        .onTapGesture { ui.librarySelected = m.id }
        .onDrag {
            ComponentCommands.beginCanvasDrag()
            return NSItemProvider(object: (ComponentCommands.libraryDragPrefix + m.id.uuidString + "|" + url.path) as NSString)
        }
        .contextMenu {
            Button("Place in Document") { if let d = doc { ComponentCommands.placeFromLibrary(d, library: url, component: m.id) } }.disabled(doc == nil)
            if let d = doc, let mine = inDoc, (mine.library?.version ?? 0) < m.version {
                Button("Update Document from Library") { ComponentCommands.updateFromLibrary(d, m.id) }
            }
            Divider()
            Button("Remove from Library") { try? ComponentLibraries.remove(m.id, from: url); ui.libraryTick += 1 }
        }
    }
}

// MARK: - Properties panel section (instances)

struct ComponentInstanceProperties: View {
    @Bindable var doc: Document
    let layerID: UUID

    var body: some View {
        if let l = doc.state.layer(layerID), let inst = l.componentInstance {
            if let m = doc.state.components[inst.componentID] {
                InstanceEditor(doc: doc, layerID: layerID, inst: inst, master: m)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Main component missing").foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Detach") { ComponentActions.detach(doc, layers: [layerID]) }.buttonStyle(PanelButtonStyle())
                }
            }
            Divider()
        }
    }
}

struct InstanceEditor: View {
    @Bindable var doc: Document
    let layerID: UUID
    let inst: ComponentInstance
    let master: ComponentMaster
    static let purple = Color(red: 0.62, green: 0.45, blue: 0.95)

    var body: some View {
        let others = ComponentEngine.sorted(doc.state.components).filter { $0.id != master.id }
        HStack(spacing: 6) {
            Image(systemName: "rhombus.fill").font(.system(size: 10)).foregroundStyle(Self.purple)
            Text(master.name).font(Theme.fontBold).lineLimit(1)
            Spacer()
            Text("Instance").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        if !master.variants.isEmpty {
            HStack(spacing: 6) {
                Text("Variant").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { inst.variantID }, set: { ComponentActions.setVariant(doc, layer: layerID, $0) })) {
                    ForEach(Array(master.variantChoices.enumerated()), id: \.offset) { _, v in Text(tr(v.name)).tag(v.id) }
                }.labelsHidden().controlSize(.small)
            }
        }
        HStack(spacing: 4) {
            Button("Edit Main") { ComponentActions.editMain(doc, component: master.id, variant: inst.variantID) }.buttonStyle(PanelButtonStyle())
                .help("Edit Main Component: opens it as a document; saving (⌘S) updates every instance")
            Menu {
                if others.isEmpty { Text("No other components in this document") }
                ForEach(others) { o in Button(tr(o.name)) { ComponentActions.swap(doc, layer: layerID, to: o.id) } }
            } label: { Text("Swap").font(Theme.font) }
            .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
            .help("Swap Component: overrides are kept where a layer of the same name exists")
            Spacer()
            Button("Detach") { ComponentActions.detach(doc, layers: [layerID]) }.buttonStyle(PanelButtonStyle())
                .help("Detach Instance: becomes normal layers (⌥⌘B)")
        }
        TintRow(doc: doc, layerID: layerID, tint: inst.tint)
        HStack {
            Caption(inst.overrideCount == 0 ? "Overrides" : "Overrides (\(inst.overrideCount))")
            Spacer()
            if inst.hasOverrides {
                Button("Reset All") { ComponentActions.resetAll(doc, layer: layerID) }.buttonStyle(.plain).font(Theme.fontSmall).foregroundStyle(Theme.accent)
            }
        }
        let rows = ComponentEngine.overridableLayers(master.tree(inst.variantID).layers)
        VStack(spacing: 3) {
            ForEach(rows, id: \.layer.id) { r in
                OverrideRow(doc: doc, layerID: layerID, inst: inst, inner: r.layer, depth: r.depth)
                    .id("\(layerID)-\(r.layer.id)-\(inst.override(r.layer.id, .text)?.text ?? r.layer.text?.text ?? "")")   // re-seed the field after undo / reset
            }
        }
        if !inst.overrides.isEmpty {
            HStack(spacing: 4) {
                Button("Push to Main") { ComponentCommands.push() }.buttonStyle(PanelButtonStyle())
                    .help("Push overrides to main: the main component (and all its instances) take this instance's overrides")
                Button("Save as Variant…") { ComponentCommands.saveAsVariant() }.buttonStyle(PanelButtonStyle())
                    .help("The instance's current look becomes a new named variant")
            }
        }
    }
}

struct TintRow: View {
    @Bindable var doc: Document
    let layerID: UUID
    let tint: ComponentTint?

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Tint", isOn: Binding(get: { tint != nil }, set: { on in
                ComponentActions.setTint(doc, layer: layerID, on ? ComponentTint(color: AppModel.shared.foreground, amount: 0.6) : nil)
            })).toggleStyle(.checkbox).font(Theme.font)
            if let t = tint {
                ColorWell(color: Binding(get: { t.color }, set: { c in
                    ComponentActions.setTint(doc, layer: layerID, ComponentTint(color: c, amount: t.amount, blendMode: t.blendMode), commit: false)
                }), size: 16, onCommit: { doc.commit("Tint Instance") })
                ValueSlider(label: "", value: Binding(get: { t.amount * 100 }, set: { v in
                    ComponentActions.setTint(doc, layer: layerID, ComponentTint(color: t.color, amount: v / 100, blendMode: t.blendMode), commit: false)
                }), range: 0...100, unit: "%", onCommit: { doc.commit("Tint Instance") })
                Button { ComponentActions.setTint(doc, layer: layerID, nil) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).help("Reset tint")
            } else {
                Spacer()
            }
        }
    }
}

/// One inner layer of the component: the controls for what this instance may override.
struct OverrideRow: View {
    @Bindable var doc: Document
    let layerID: UUID
    let inst: ComponentInstance
    let inner: Layer
    let depth: Int
    @State private var text: String
    @State private var fieldID = UUID()
    @FocusState private var focused: Bool

    init(doc: Document, layerID: UUID, inst: ComponentInstance, inner: Layer, depth: Int) {
        self.doc = doc; self.layerID = layerID; self.inst = inst; self.inner = inner; self.depth = depth
        _text = State(initialValue: inst.override(inner.id, .text)?.text ?? inner.text?.text ?? "")
    }

    var symbol: String {
        switch inner.content {
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .raster: return "photo"
        case .smartObject(let so): return so.component == nil ? "photo.on.rectangle" : "rhombus"
        case .fill: return "drop.fill"
        case .group: return inner.vectorMask != nil ? "photo.artframe" : "folder"
        case .adjustment: return "circle.lefthalf.filled"
        }
    }

    var body: some View {
        let kinds = ComponentEngine.overridableKinds(inner)
        let mine = inst.overrides.filter { $0.layerID == inner.id }
        let visible = inst.override(inner.id, .visible)?.visible ?? inner.isVisible
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Button { ComponentActions.setVisible(doc, layer: layerID, inner: inner, !visible) } label: {
                    Image(systemName: visible ? "eye" : "eye.slash").font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(inst.override(inner.id, .visible) != nil ? Theme.accent : Theme.textDim)
                }.buttonStyle(.plain).help(tr(visible ? "Hide in this instance" : "Show in this instance"))
                Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(Theme.textDim).frame(width: 12)
                Text(tr(inner.name)).lineLimit(1).foregroundStyle(visible ? Theme.text : Theme.textFaint)
                Spacer(minLength: 2)
                if kinds.contains(.fill) { colorWell(.fill) }
                if kinds.contains(.stroke) { colorWell(.stroke) }
                if kinds.contains(.image) {
                    Button(tr(inst.override(inner.id, .image) == nil ? "Replace…" : "Replaced")) {
                        if let (img, name) = ComponentPrompts.image() { ComponentActions.setImage(doc, layer: layerID, inner: inner, img, name: name) }
                    }
                    .buttonStyle(.plain).font(Theme.fontSmall)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                    .foregroundStyle(inst.override(inner.id, .image) != nil ? Theme.accent : Theme.text)
                    .help("Replace the image in this instance only")
                }
            }
            if kinds.contains(.text) {
                // typed text also counts when a button is clicked straight after typing (see FieldEdits)
                TextField(tr(inner.text?.text ?? ""), text: Binding(get: { text }, set: { v in
                    text = v
                    FieldEdits.edited(fieldID, commit: commitText, discard: { text = inst.override(inner.id, .text)?.text ?? inner.text?.text ?? "" })
                }))
                    .textFieldStyle(.plain).font(Theme.font).focused($focused)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(inst.override(inner.id, .text) != nil ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1))
                    .onSubmit { commitText() }
                    .onChange(of: focused) { _, f in if !f { commitText() } }
                    .padding(.leading, 19)
            }
            if !mine.isEmpty {
                // the override table for this layer, each entry individually resettable
                ForEach(mine) { o in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        Text("\(tr(o.kind.label)): \(o.summary)").font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
                        Spacer()
                        Button { ComponentActions.resetOverride(doc, layer: layerID, inner: inner.id, kind: o.kind) } label: {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                        }.buttonStyle(.plain).foregroundStyle(Theme.accent).help("Reset to the main component (\(ComponentEngine.masterValue(inner, o.kind)))")
                    }.padding(.leading, 19)
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 10)
        .padding(.horizontal, 5).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(mine.isEmpty ? Theme.fieldBG.opacity(0.35) : Theme.accent.opacity(0.10)))
    }

    private func commitText() {
        FieldEdits.ended(fieldID)
        let current = inst.override(inner.id, .text)?.text ?? inner.text?.text ?? ""
        guard text != current else { return }
        if text == inner.text?.text { ComponentActions.resetOverride(doc, layer: layerID, inner: inner.id, kind: .text) }
        else { ComponentActions.setText(doc, layer: layerID, inner: inner, text) }
    }

    @ViewBuilder private func colorWell(_ kind: ComponentOverrideKind) -> some View {
        let over = inst.override(inner.id, kind)
        ColorWell(color: Binding(get: { over?.color ?? ComponentEngine.masterColor(inner, kind) }, set: { c in
            ComponentActions.setColor(doc, layer: layerID, inner: inner, kind: kind, c, commit: false)
        }), size: 14, onCommit: { doc.commit("Override \(kind.label)") })
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(over != nil ? Theme.accent : Color.clear, lineWidth: 1.5))
        .help(tr(kind == .stroke ? "Stroke colour in this instance" : "Fill colour in this instance"))
    }
}

// MARK: - Layers panel hooks

/// Small diamond next to instance layers (filled dot when the instance has overrides).
struct ComponentLayerBadge: View {
    let layer: Layer
    var body: some View {
        if let inst = layer.componentInstance {
            HStack(spacing: 1) {
                Image(systemName: "rhombus.fill").font(.system(size: 8)).foregroundStyle(InstanceEditor.purple)
                if inst.hasOverrides { Circle().fill(Theme.accent).frame(width: 4, height: 4) }
            }
            .help(tr(inst.hasOverrides ? "Component instance with \(inst.overrideCount) override\(inst.overrideCount == 1 ? "" : "s")" : "Component instance"))
        }
    }
}

struct ComponentLayerContextMenu: View {
    @Bindable var doc: Document
    let layerID: UUID
    var body: some View {
        if let inst = doc.state.layer(layerID)?.componentInstance {
            let others = ComponentEngine.sorted(doc.state.components).filter { $0.id != inst.componentID }
            Button("Edit Main Component") { ComponentActions.editMain(doc, component: inst.componentID, variant: inst.variantID) }
            Menu("Swap Component") {
                ForEach(others) { o in Button(tr(o.name)) { ComponentActions.swap(doc, layer: layerID, to: o.id) } }
            }.disabled(others.isEmpty)
            Button("Reset All Overrides") { ComponentActions.resetAll(doc, layer: layerID) }.disabled(!inst.hasOverrides)
            Button("Push Overrides to Main") { doc.selectLayer(layerID); ComponentCommands.push() }.disabled(inst.overrides.isEmpty)
            Button("Select All Instances") { ComponentActions.selectInstances(doc, component: inst.componentID) }
            Button("Detach Instance") { ComponentActions.detach(doc, layers: [layerID]) }
            Divider()
        } else {
            Button("Create Component") {
                if !doc.selectedLayerIDs.contains(layerID) { doc.selectLayer(layerID) }
                ComponentCommands.create()
            }
            Divider()
        }
    }
}
