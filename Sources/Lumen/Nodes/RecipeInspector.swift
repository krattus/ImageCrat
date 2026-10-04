import SwiftUI
import AppKit
import ImageCratCore

/// Right-hand side of the Recipe Editor: the selected node's parameters, or the recipe's own settings.
struct RecipeInspectorView: View {
    @Bindable var model: RecipeEditorModel
    @State private var showAllSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let n = model.singleSelection {
                    nodeInspector(n)
                } else if model.selection.count > 1 {
                    Text("\(model.selection.count) nodes selected").font(Theme.fontBold)
                    HStack {
                        Button("Duplicate") { model.duplicateSelection() }.buttonStyle(PanelButtonStyle())
                        Button("Frame") { model.addFrame() }.buttonStyle(PanelButtonStyle())
                        Button("Delete") { model.deleteSelection() }.buttonStyle(PanelButtonStyle())
                    }
                    Text("Use the align menu in the toolbar to line them up.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                } else if let fid = model.selectedFrame, let f = model.graph?.frames.first(where: { $0.id == fid }) {
                    frameInspector(f)
                } else {
                    recipeInspector
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panelBG)
    }

    // MARK: Node

    @ViewBuilder func nodeInspector(_ n: RecipeNode) -> some View {
        let spec = RecipeLibrary.spec(n.type)
        let g = model.graph ?? RecipeGraph()
        HStack(spacing: 6) {
            Image(systemName: spec?.category.symbol ?? "questionmark").foregroundStyle(Color(nsColor: (spec?.category.rgba ?? RGBA(gray: 0.5)).nsColor))
            Text(spec?.name ?? n.type).font(Theme.fontBold)
            Spacer()
            Text(spec.map { $0.group.isEmpty ? $0.category.rawValue : $0.category.rawValue + " · " + $0.group } ?? "").font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
        }
        TextField("Label", text: Binding(get: { n.title ?? "" }, set: { v in model.mutate(nil) { $0.update(n.id) { $0.title = v.isEmpty ? nil : v } } }))
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.commit("Rename Node") }
        HStack(spacing: 4) {
            IconButton(symbol: n.muted ? "speaker.slash.fill" : "speaker.slash", help: "Mute / bypass (M)", active: n.muted) { model.toggleMute() }
            IconButton(symbol: g.solo == n.id ? "eye.fill" : "eye", help: "View this node on the canvas (V)", active: g.solo == n.id) { model.toggleSolo(n.id) }
            IconButton(symbol: "photo", help: "Show preview in the node (P)", active: n.showPreview) { model.togglePreview() }
            IconButton(symbol: n.collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical", help: "Collapse the node (H)", active: n.collapsed) { model.toggleCollapse() }
            Spacer()
        }
        if let e = model.errors[n.id] {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(Theme.fontSmall)
        }
        if let spec {
            if !spec.params.isEmpty {
                Divider()
                HStack { Caption("Parameters"); Spacer(); Text("pin = show in Properties").font(.system(size: 9)).foregroundStyle(Theme.textFaint) }
            }
            ForEach(spec.params, id: \.key) { p in
                let conn = p.portType != nil ? g.input(n.id, p.portName) : nil
                HStack(alignment: .top, spacing: 4) {
                    Button { model.toggleExposed(n.id, p.key) } label: {
                        Image(systemName: model.isExposed(n.id, p.key) ? "pin.fill" : "pin").font(.system(size: 9))
                            .foregroundStyle(model.isExposed(n.id, p.key) ? Theme.accent : Theme.textFaint).frame(width: 12, height: 16)
                    }.buttonStyle(.plain).help("Expose in the Properties panel")
                    if let c = conn, let src = g.node(c.from) {
                        HStack {
                            Text(p.label).foregroundStyle(Theme.textDim)
                            Spacer()
                            Text("← \(src.title ?? RecipeLibrary.spec(src.type)?.name ?? "node")").foregroundStyle(Color(nsColor: (p.portType ?? .number).rgba.nsColor)).lineLimit(1)
                            Button { model.disconnect(c.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Disconnect")
                        }
                    } else {
                        RecipeParamControl(spec: p, node: n, layers: model.document?.state.allLayers.filter { $0.id != model.target.layerID || p.label.contains("empty") } ?? [],
                                           edit: { body in model.mutate(nil) { $0.update(n.id, body) } }, commit: { model.commit(p.label) })
                    }
                }
            }
            if let kind = spec.adjustmentKind {
                Divider()
                SectionHeader(title: "All \(kind.displayName) Settings", expanded: $showAllSettings)
                if showAllSettings || RecipeAdjustKey.keys(kind).isEmpty {
                    AdjustmentControls(s: Binding(get: { RecipeAdjustKey.settings(n, kind: kind) }, set: { v in
                        model.mutate(nil) { $0.update(n.id) { RecipeAdjustKey.store(v, in: &$0) } }
                    }), doc: model.document, onCommit: { model.commit(kind.displayName) })
                }
            }
            Divider()
            Caption("Ports")
            ForEach(spec.inputs, id: \.name) { i in portLine(i.name, i.type, input: true, conn: g.input(n.id, i.name), g) }
            ForEach(spec.outputs, id: \.name) { o in
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: o.type.rgba.nsColor)).frame(width: 7, height: 7)
                    Text("out · \(o.name)").foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(o.type.displayName).foregroundStyle(Theme.textFaint)
                }.font(Theme.fontSmall)
            }
        }
    }

    func portLine(_ name: String, _ type: RecipePortType, input: Bool, conn: RecipeConnection?, _ g: RecipeGraph) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color(nsColor: type.rgba.nsColor)).frame(width: 7, height: 7)
            Text("in · \(name)").foregroundStyle(Theme.textDim)
            Spacer()
            if let c = conn, let src = g.node(c.from) {
                Text(src.title ?? RecipeLibrary.spec(src.type)?.name ?? "node").lineLimit(1)
                Button { model.disconnect(c.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Disconnect")
            } else {
                Text("not connected").foregroundStyle(Theme.textFaint)
            }
        }.font(Theme.fontSmall)
    }

    // MARK: Frame

    @ViewBuilder func frameInspector(_ f: RecipeFrame) -> some View {
        Text("Frame").font(Theme.fontBold)
        TextField("Title", text: Binding(get: { f.title }, set: { v in model.mutate(nil) { g in if let i = g.frames.firstIndex(where: { $0.id == f.id }) { g.frames[i].title = v } } }))
            .textFieldStyle(.roundedBorder).onSubmit { model.commit("Rename Frame") }
        TextField("Comment", text: Binding(get: { f.note }, set: { v in model.mutate(nil) { g in if let i = g.frames.firstIndex(where: { $0.id == f.id }) { g.frames[i].note = v } } }))
            .textFieldStyle(.roundedBorder).onSubmit { model.commit("Frame Comment") }
        HStack(spacing: 5) {
            Text("Color").foregroundStyle(Theme.textDim)
            ForEach(["4A76B8", "B84A4A", "C27A3A", "4F9A55", "8A5AB8", "7A7A7A"], id: \.self) { hex in
                Circle().fill(Color(nsColor: RGBA(hex: hex)!.nsColor)).frame(width: 15, height: 15)
                    .overlay(Circle().stroke(Color.white, lineWidth: f.color.hex == hex ? 1.5 : 0))
                    .onTapGesture { model.mutate("Frame Color") { g in if let i = g.frames.firstIndex(where: { $0.id == f.id }) { g.frames[i].color = RGBA(hex: hex)! } } }
            }
        }
        HStack {
            NumberField(label: "W", value: Binding(get: { Double(f.rect.width) }, set: { v in model.mutate(nil) { g in if let i = g.frames.firstIndex(where: { $0.id == f.id }) { g.frames[i].rect.size.width = max(80, v) } } }),
                        width: 50, onCommit: { model.commit("Resize Frame") })
            NumberField(label: "H", value: Binding(get: { Double(f.rect.height) }, set: { v in model.mutate(nil) { g in if let i = g.frames.firstIndex(where: { $0.id == f.id }) { g.frames[i].rect.size.height = max(60, v) } } }),
                        width: 50, onCommit: { model.commit("Resize Frame") })
        }
        Button("Delete Frame") { model.deleteSelection() }.buttonStyle(PanelButtonStyle())
        Text("Drag the title bar to move the frame together with the nodes inside it; drag the corner grip to resize.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
    }

    // MARK: Recipe

    @ViewBuilder var recipeInspector: some View {
        let g = model.graph ?? RecipeGraph()
        Text("Recipe").font(Theme.fontBold)
        TextField("Name", text: Binding(get: { g.name }, set: { v in model.mutate(nil) { $0.name = v } }))
            .textFieldStyle(.roundedBorder).onSubmit { model.commit("Rename Recipe") }
        Text("\(g.nodes.count) nodes · \(g.connections.count) wires · \(g.frames.count) frames").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        Divider()
        Caption("Exposed parameters")
        if g.exposed.isEmpty {
            Text("Select a node and click the pin next to a parameter to show it in the Properties panel — the recipe then works like a custom filter with just those controls.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(g.exposed.enumerated()), id: \.element.id) { i, e in
            HStack(spacing: 4) {
                TextField("", text: Binding(get: { e.label }, set: { v in model.mutate(nil) { $0.exposed[i].label = v } }))
                    .textFieldStyle(.plain).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                    .onSubmit { model.commit("Rename Parameter") }
                Text(g.node(e.node).map { $0.title ?? RecipeLibrary.spec($0.type)?.name ?? "" } ?? "missing").font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1).frame(maxWidth: 70, alignment: .trailing)
                Button { model.mutate("Reorder Parameters") { if i > 0 { $0.exposed.swapAt(i, i - 1) } } } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(i == 0)
                Button { model.mutate("Reorder Parameters") { if i < $0.exposed.count - 1 { $0.exposed.swapAt(i, i + 1) } } } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(i == g.exposed.count - 1)
                Button { model.mutate("Hide Parameter") { $0.exposed.remove(at: i) } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                Button { model.selectOnly(e.node) } label: { Image(systemName: "scope") }.buttonStyle(.plain).help("Select the node")
            }
        }
        Divider()
        Caption("Shortcuts")
        VStack(alignment: .leading, spacing: 2) {
            ForEach(["Tab / ⇧A — search & add a node", "Right-click — add menu", "Drag a socket — wire (drop on empty space to add a node)",
                     "Drag background — box select · ⌥drag — pan", "M mute · V view node · H collapse · P preview", "⌘C ⌘V ⌘D ⌘G — copy, paste, duplicate, frame",
                     "⌘Z / ⇧⌘Z — undo / redo (document history)"], id: \.self) { Text($0) }
        }.font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
    }
}
