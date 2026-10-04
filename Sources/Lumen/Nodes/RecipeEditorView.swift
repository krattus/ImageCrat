import SwiftUI
import AppKit
import ImageCratCore

// MARK: - Editor root

struct RecipeEditorView: View {
    @Bindable var model: RecipeEditorModel
    @State private var presetName = ""
    @State private var askName = false

    var body: some View {
        VStack(spacing: 0) {
            if model.exists {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    RecipeCanvasView(model: model)
                    Divider()
                    RecipeInspectorView(model: model).frame(width: 276)
                }
                Divider()
                statusBar
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundStyle(Theme.textFaint)
                    Text("This recipe no longer exists.").foregroundStyle(Theme.textDim)
                    Text("Select a Recipe layer and choose Layer ▸ Edit Recipe…").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.panelBG)
        .font(Theme.font)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, Theme.colorScheme)
        .onAppear { model.schedulePreviews(delay: 0.05); RecipePresetStore.shared.loadIfNeeded() }
        .onChange(of: model.document?.revision) { _, _ in model.schedulePreviews() }
    }

    var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                RecipeAddMenu { type in model.addNode(type, at: model.toGraph(CGPoint(x: model.viewSize.width / 2 - 100, y: model.viewSize.height / 2 - 60))) }
            } label: { Label("Add Node", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
            IconButton(symbol: "magnifyingglass", help: "Search nodes (Tab)") { model.search = .init(position: model.toGraph(CGPoint(x: model.viewSize.width / 2 - 100, y: 80))) }
            Divider().frame(height: 16)
            IconButton(symbol: "rectangle.dashed", help: "Frame the selection (⌘G)") { model.addFrame() }
            Menu {
                Button("Align Left") { model.align(.left) }
                Button("Align Horizontal Centers") { model.align(.hCenter) }
                Button("Align Right") { model.align(.right) }
                Divider()
                Button("Align Top") { model.align(.top) }
                Button("Align Vertical Centers") { model.align(.vCenter) }
                Button("Align Bottom") { model.align(.bottom) }
                Divider()
                Button("Distribute Horizontally") { model.align(.distributeH) }
                Button("Distribute Vertically") { model.align(.distributeV) }
            } label: { Image(systemName: "align.horizontal.left") }
            .menuStyle(.borderlessButton).fixedSize().help("Align selected nodes").disabled(model.selection.count < 2)
            Divider().frame(height: 16)
            IconButton(symbol: "speaker.slash", help: "Mute / bypass (M)") { model.toggleMute() }
            IconButton(symbol: "eye", help: "View this node on the canvas (V) — again to view the Output", active: model.graph?.solo != nil) { model.toggleSolo(model.selection.first) }
            IconButton(symbol: "plus.square.on.square", help: "Duplicate (⌘D)") { model.duplicateSelection() }
            IconButton(symbol: "trash", help: "Delete (⌫)") { model.deleteSelection() }
            Divider().frame(height: 16)
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit all (F)") { model.fitView() }
            IconButton(symbol: "minus.magnifyingglass", help: "Zoom out") { model.zoom(by: 0.8) }
            Text("\(Int((model.zoom * 100).rounded()))%").font(Theme.mono).foregroundStyle(Theme.textDim).frame(width: 38)
            IconButton(symbol: "plus.magnifyingglass", help: "Zoom in") { model.zoom(by: 1.25) }
            Spacer()
            if let s = model.graph?.solo, let n = model.graph?.node(s) {
                Button { model.toggleSolo(nil) } label: {
                    Label("Viewing: \(n.title ?? RecipeLibrary.spec(n.type)?.name ?? "node")", systemImage: "eye.fill")
                }.buttonStyle(PanelButtonStyle(prominent: true)).help("Click to view the Output again")
            }
            Menu {
                Section("Built-in") { ForEach(RecipePresets.builtIn) { p in Button(p.name) { model.loadPreset(p) } } }
                let user = RecipePresetStore.shared.user
                if !user.isEmpty { Section("My Recipes") { ForEach(user) { p in Button(p.name) { model.loadPreset(p) } } } }
            } label: { Label("Presets", systemImage: "books.vertical") }
            .menuStyle(.borderlessButton).fixedSize().help("Replace the graph with a preset")
            Button("Save Preset…") { presetName = model.graph?.name ?? "Recipe"; askName = true }.buttonStyle(PanelButtonStyle())
                .popover(isPresented: $askName) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save as Recipe Preset").font(Theme.fontBold)
                        TextField("Name", text: $presetName).textFieldStyle(.roundedBorder).frame(width: 220)
                        HStack { Spacer(); Button("Cancel") { askName = false }; Button("Save") { model.saveAsPreset(name: presetName); askName = false }.keyboardShortcut(.defaultAction) }
                    }.padding(12)
                }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.panelHeader)
    }

    var statusBar: some View {
        HStack(spacing: 10) {
            if let e = model.graphError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            else if !model.errors.isEmpty { Label("\(model.errors.count) node\(model.errors.count == 1 ? "" : "s") with a problem", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Text(model.status).foregroundStyle(Theme.textDim).lineLimit(1)
            Spacer()
            Text("\(model.graph?.nodes.count ?? 0) nodes · Tab: add · drag sockets to wire · scroll: pan · ⌘scroll / pinch: zoom").foregroundStyle(Theme.textFaint).lineLimit(1)
        }
        .font(Theme.fontSmall)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.panelHeader)
    }
}

/// Category ▸ group ▸ node menu items.
struct RecipeAddMenu: View {
    let add: (String) -> Void
    var body: some View {
        ForEach(RecipeCategory.allCases, id: \.self) { cat in
            Menu {
                ForEach(RecipeLibrary.groups(cat), id: \.self) { grp in
                    let items = RecipeLibrary.byCategory(cat).filter { $0.group == grp }
                    if grp.isEmpty {
                        ForEach(items, id: \.type) { s in Button(s.name) { add(s.type) } }
                    } else {
                        Menu(grp) { ForEach(items, id: \.type) { s in Button(s.name) { add(s.type) } } }
                    }
                }
            } label: { Label(cat.rawValue, systemImage: cat.symbol) }
        }
    }
}

// MARK: - Canvas

struct RecipeCanvasView: View {
    @Bindable var model: RecipeEditorModel
    static let space = "recipeCanvas"

    var body: some View {
        GeometryReader { geo in
            let g = model.graph ?? RecipeGraph()
            let pan = model.pan, zoom = model.zoom
            let wire = model.wire, box = model.box
            let selFrame = model.selectedFrame
            // positions including live drags (read here so the Canvas redraws while dragging)
            let nodes = g.nodes.map { n -> RecipeNode in var m = n; m.position = model.position(n); return m }
            let frames = g.frames.map { f -> RecipeFrame in var m = f; m.rect = model.rect(f); return m }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    RecipeCanvasView.drawBackground(&ctx, size: size, pan: pan, zoom: zoom)
                    ctx.translateBy(x: pan.x, y: pan.y)
                    ctx.scaleBy(x: zoom, y: zoom)
                    for f in frames { RecipeCanvasView.drawFrame(&ctx, f, selected: selFrame == f.id) }
                    let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                    for c in g.connections {
                        guard let a = byID[c.from], let b = byID[c.to] else { continue }
                        let t0 = RecipeLibrary.outputType(a, c.fromPort) ?? .image, t1 = RecipeLibrary.inputType(b, c.toPort) ?? t0
                        RecipeCanvasView.drawWire(&ctx, from: RecipeLibrary.outputPosition(a, c.fromPort), to: RecipeLibrary.inputPosition(b, c.toPort),
                                                  type: t0, toType: t1, dim: a.muted)
                    }
                    if let w = wire, let n = byID[w.node] {
                        let p0 = w.fromOutput ? RecipeLibrary.outputPosition(n, w.port) : w.point
                        let p1 = w.fromOutput ? w.point : RecipeLibrary.inputPosition(n, w.port)
                        RecipeCanvasView.drawWire(&ctx, from: p0, to: p1, type: w.type, toType: w.type, dim: false, dashed: true)
                    }
                    if let b = box {
                        ctx.fill(Path(b), with: .color(Theme.accent.opacity(0.12)))
                        ctx.stroke(Path(b), with: .color(Theme.accent), lineWidth: 1 / zoom)
                    }
                }
                .contentShape(Rectangle())
                .gesture(backgroundDrag)
                .onTapGesture { p in
                    if let f = model.frameTitleHit(model.toGraph(p)) { model.selectedFrame = f; model.selection = [] } else { model.clearSelection() }
                    model.search = nil
                }
                .contextMenu {
                    RecipeAddMenu { type in model.addNode(type, at: model.mouseGraph) }
                    Divider()
                    Button("Search Nodes…") { model.search = .init(position: model.mouseGraph) }
                    Button("Paste") { model.paste() }.disabled(!model.canPaste)
                    Button("Add Frame") { model.addFrame() }
                    Button("Select All") { model.selectAll() }
                    Button("Fit All") { model.fitView() }
                }

                ForEach(nodes) { n in
                    RecipeNodeView(model: model, node: n, graph: g)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .offset(x: pan.x + n.position.x * zoom, y: pan.y + n.position.y * zoom)
                }

                if let s = model.search {
                    RecipeSearchPopup(model: model)
                        .offset(x: min(max(8, model.toView(s.position).x), max(8, geo.size.width - 270)), y: min(max(8, model.toView(s.position).y), max(8, geo.size.height - 330)))
                }
                if g.nodes.isEmpty {
                    Text("Right-click or press Tab to add nodes").foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: RecipeCanvasView.space)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): model.mouseView = p; model.hovering = true
                case .ended: model.hovering = false
                }
            }
            .gesture(MagnifyGesture().onChanged { v in
                let f = v.magnification / (lastMag ?? 1)
                lastMag = v.magnification
                model.zoom(by: f, around: model.mouseView)
            }.onEnded { _ in lastMag = nil })
            .onAppear { model.viewSize = geo.size; if !model.didInitialFit { model.didInitialFit = true; model.fitView() } }
            .onChange(of: geo.size) { _, s in model.viewSize = s }
        }
    }

    @State private var lastMag: CGFloat?
    @State private var dragMode = 0   // 0 none, 1 box, 2 pan, 3 move frame, 4 resize frame

    /// Drag on empty canvas: box-select (Option or Space-less default), pan with Option, move a frame by its title.
    var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(RecipeCanvasView.space))
            .onChanged { v in
                if dragMode == 0 {
                    let start = model.toGraph(v.startLocation)
                    model.focusCanvas()
                    if let f = model.frameGripHit(start) { dragMode = 4; model.resizingFrame = f; model.selectedFrame = f; model.selection = [] }
                    else if let f = model.frameTitleHit(start) { dragMode = 3; model.draggingFrame = f; model.selectedFrame = f; model.selection = [] }
                    else if NSEvent.modifierFlags.contains(.option) || NSEvent.pressedMouseButtons & 4 != 0 { dragMode = 2; panStart = model.pan }
                    else { dragMode = 1 }
                }
                switch dragMode {
                case 1:
                    let a = model.toGraph(v.startLocation), b = model.toGraph(v.location)
                    model.box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                case 2:
                    model.pan = CGPoint(x: panStart.x + v.translation.width, y: panStart.y + v.translation.height)
                case 3, 4:
                    model.dragOffset = CGSize(width: v.translation.width / model.zoom, height: v.translation.height / model.zoom)
                default: break
                }
            }
            .onEnded { _ in
                switch dragMode {
                case 1: model.finishBox(extend: NSEvent.modifierFlags.contains(.shift))
                case 3: model.endFrameDrag()
                case 4: model.endFrameResize()
                default: break
                }
                dragMode = 0
            }
    }
    @State private var panStart = CGPoint.zero

    // MARK: Drawing

    static func drawBackground(_ ctx: inout GraphicsContext, size: CGSize, pan: CGPoint, zoom: CGFloat) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.115)))
        let step = 20 * zoom
        guard step >= 5 else { return }
        var minor = Path(), major = Path()
        var i = Int(floor(-pan.x / step))
        var x = pan.x + CGFloat(i) * step
        while x < size.width {
            if i % 5 == 0 { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height)) }
            else { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height)) }
            x += step; i += 1
        }
        var j = Int(floor(-pan.y / step))
        var y = pan.y + CGFloat(j) * step
        while y < size.height {
            if j % 5 == 0 { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: size.width, y: y)) }
            else { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y)) }
            y += step; j += 1
        }
        ctx.stroke(minor, with: .color(Color(white: 0.145)), lineWidth: 1)
        ctx.stroke(major, with: .color(Color(white: 0.175)), lineWidth: 1)
    }

    static func drawFrame(_ ctx: inout GraphicsContext, _ f: RecipeFrame, selected: Bool) {
        let col = Color(nsColor: f.color.nsColor)
        let shape = Path(roundedRect: f.rect, cornerRadius: 8)
        ctx.fill(shape, with: .color(col.opacity(0.13)))
        ctx.stroke(shape, with: .color(col.opacity(selected ? 1 : 0.55)), lineWidth: selected ? 2 : 1)
        var clipped = ctx
        clipped.clip(to: shape)
        clipped.fill(Path(CGRect(x: f.rect.minX, y: f.rect.minY, width: f.rect.width, height: 22)), with: .color(col.opacity(0.45)))
        ctx.draw(Text(f.title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: f.rect.minX + 9, y: f.rect.minY + 11), anchor: .leading)
        var grip = Path()
        grip.move(to: CGPoint(x: f.rect.maxX - 4, y: f.rect.maxY - 12)); grip.addLine(to: CGPoint(x: f.rect.maxX - 12, y: f.rect.maxY - 4))
        grip.move(to: CGPoint(x: f.rect.maxX - 4, y: f.rect.maxY - 7)); grip.addLine(to: CGPoint(x: f.rect.maxX - 7, y: f.rect.maxY - 4))
        ctx.stroke(grip, with: .color(col.opacity(0.9)), lineWidth: 1.2)
        if !f.note.isEmpty {
            ctx.draw(Text(f.note).font(.system(size: 10)).foregroundColor(Color(white: 0.75)), at: CGPoint(x: f.rect.minX + 9, y: f.rect.maxY - 10), anchor: .leading)
        }
    }

    static func wirePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        let dx = max(40, abs(b.x - a.x) * 0.5)
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }

    static func drawWire(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, type: RecipePortType, toType: RecipePortType, dim: Bool, dashed: Bool = false) {
        let p = wirePath(a, b)
        let c0 = Color(nsColor: type.rgba.nsColor).opacity(dim ? 0.35 : 1), c1 = Color(nsColor: toType.rgba.nsColor).opacity(dim ? 0.35 : 1)
        ctx.stroke(p, with: .color(.black.opacity(0.45)), style: SwiftUI.StrokeStyle(lineWidth: 4.5, lineCap: .round))
        let shading: GraphicsContext.Shading = type == toType ? .color(c0) : .linearGradient(Gradient(colors: [c0, c1]), startPoint: a, endPoint: b)
        ctx.stroke(p, with: shading, style: SwiftUI.StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: dashed ? [6, 4] : []))
        if type != toType {
            // conversion marker at the middle of the wire
            let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            var d = Path()
            d.move(to: CGPoint(x: m.x - 5, y: m.y)); d.addLine(to: CGPoint(x: m.x, y: m.y - 5)); d.addLine(to: CGPoint(x: m.x + 5, y: m.y)); d.addLine(to: CGPoint(x: m.x, y: m.y + 5)); d.closeSubpath()
            ctx.fill(d, with: .color(Color(white: 0.12)))
            ctx.stroke(d, with: .color(c1), lineWidth: 1.5)
        }
    }
}

// MARK: - Node

struct RecipeSocket: View {
    let type: RecipePortType
    let connected: Bool
    var body: some View {
        let c = Color(nsColor: type.rgba.nsColor)
        Circle().fill(connected ? c : Color(white: 0.16))
            .overlay(Circle().stroke(c, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .contentShape(Rectangle().inset(by: -5))
    }
}

struct RecipeNodeView: View {
    @Bindable var model: RecipeEditorModel
    let node: RecipeNode
    let graph: RecipeGraph

    var body: some View {
        let spec = RecipeLibrary.spec(node.type)
        let size = RecipeLibrary.nodeSize(node)
        let selected = model.selection.contains(node.id)
        let error = model.errors[node.id]
        let solo = graph.solo == node.id
        VStack(alignment: .leading, spacing: 0) {
            header(spec, error: error, solo: solo)
            if let spec {
                ForEach(spec.outputs, id: \.name) { o in outputRow(o) }
                if RecipeLibrary.hasPreview(node) { preview }
                ForEach(spec.inputs, id: \.name) { i in inputRow(i) }
                if !node.collapsed {
                    ForEach(RecipeLibrary.bodyParams(spec), id: \.key) { p in paramRow(p) }
                }
            } else {
                Text("Unknown node").foregroundStyle(.orange).font(Theme.fontSmall).padding(.horizontal, 8).frame(height: RecipeLayout.portRow)
            }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: node.muted ? 0.17 : 0.215)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(error != nil ? Color.orange : (selected ? Theme.accent : Color(white: 0.08)), lineWidth: selected || error != nil ? 2 : 1))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .opacity(node.muted ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.select(node.id, extend: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)); model.search = nil }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(RecipeCanvasView.space)).onChanged { v in
            if model.dragOffset == nil { model.focusCanvas(); if !model.selection.contains(node.id) { model.selectOnly(node.id) } }
            model.dragOffset = CGSize(width: v.translation.width / model.zoom, height: v.translation.height / model.zoom)
        }.onEnded { _ in model.endNodeDrag() })
        .contextMenu {
            Button(node.muted ? "Unmute" : "Mute (Bypass)") { model.selectOnly(node.id); model.toggleMute() }
            Button(solo ? "View Output" : "View This Node") { model.toggleSolo(node.id) }
            Button(node.showPreview ? "Hide Preview" : "Show Preview") { model.selectOnly(node.id); model.togglePreview() }
            Button(node.collapsed ? "Expand" : "Collapse") { model.selectOnly(node.id); model.toggleCollapse() }
            Divider()
            Button("Duplicate") { if !model.selection.contains(node.id) { model.selectOnly(node.id) }; model.duplicateSelection() }
            Button("Copy") { if !model.selection.contains(node.id) { model.selectOnly(node.id) }; model.copySelection() }
            Button("Disconnect All Wires") { model.disconnectAll(node.id) }
            Divider()
            Button("Delete") { if !model.selection.contains(node.id) { model.selectOnly(node.id) }; model.deleteSelection() }
        }
    }

    func header(_ spec: RecipeNodeSpec?, error: String?, solo: Bool) -> some View {
        let tint = Color(nsColor: (spec?.category.rgba ?? RGBA(gray: 0.4)).nsColor)
        return HStack(spacing: 4) {
            Image(systemName: spec?.category.symbol ?? "questionmark").font(.system(size: 9)).foregroundStyle(.white.opacity(0.85))
            Text(node.title ?? spec?.name ?? node.type).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 2)
            if let e = error { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.yellow).help(e) }
            if node.muted { Image(systemName: "speaker.slash.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)) }
            if solo { Image(systemName: "eye.fill").font(.system(size: 10)).foregroundStyle(.white) }
        }
        .padding(.horizontal, 7)
        .frame(height: RecipeLayout.header)
        .background(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6).fill(tint.opacity(node.muted ? 0.5 : 1)))
    }

    func outputRow(_ o: RecipePortSpec) -> some View {
        HStack(spacing: 4) {
            Spacer()
            Text(o.name).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
            RecipeSocket(type: o.type, connected: graph.connections.contains { $0.from == node.id && $0.fromPort == o.name })
                .offset(x: 5)
                .gesture(socketDrag(port: o.name, isOutput: true))
                .help(o.type.displayName)
        }
        .frame(height: RecipeLayout.portRow)
    }

    func inputRow(_ i: RecipePortSpec) -> some View {
        let conn = graph.input(node.id, i.name)
        return HStack(spacing: 4) {
            RecipeSocket(type: i.type, connected: conn != nil)
                .offset(x: -5)
                .gesture(socketDrag(port: i.name, isOutput: false))
                .help(i.type.displayName)
            Text(i.name).font(Theme.fontSmall).foregroundStyle(conn == nil ? Theme.textFaint : Theme.text)
            Spacer()
        }
        .frame(height: RecipeLayout.portRow)
    }

    var preview: some View {
        ZStack {
            CheckerBackground(size: 5).opacity(0.5)
            if let cg = model.previews[node.id] {
                Image(decorative: cg, scale: 2).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: RecipeLayout.width - 12, height: RecipeLayout.previewHeight - 8)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.1), lineWidth: 1))
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    func socketDrag(port: String, isOutput: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(RecipeCanvasView.space))
            .onChanged { v in
                if model.wire == nil { model.beginWire(node: node.id, port: port, isOutput: isOutput, at: model.toGraph(v.startLocation)) }
                model.wire?.point = model.toGraph(v.location)
            }
            .onEnded { v in model.endWire(at: model.toGraph(v.location)) }
    }

    @ViewBuilder func paramRow(_ p: RecipeParamSpec) -> some View {
        let conn = p.portType != nil ? graph.input(node.id, p.portName) : nil
        HStack(spacing: 3) {
            if let t = p.portType {
                RecipeSocket(type: t, connected: conn != nil)
                    .offset(x: -5)
                    .gesture(socketDrag(port: p.portName, isOutput: false))
                    .help("\(t.displayName) input — drives “\(p.label)”")
            } else {
                Color.clear.frame(width: 10, height: 10).offset(x: -5)
            }
            paramControl(p, driven: conn != nil)
                .padding(.trailing, 6)
        }
        .frame(height: RecipeLayout.paramRow)
    }

    @ViewBuilder func paramControl(_ p: RecipeParamSpec, driven: Bool) -> some View {
        let id = node.id
        let num = node.numbers[p.key] ?? p.def
        switch p.kind {
        case .slider(let r):
            RecipeScrubber(label: p.label, value: num, range: r, unit: p.unit.isEmpty ? "" : " " + p.unit.trimmingCharacters(in: .whitespaces), driven: driven,
                           onChange: { model.setNumber(id, p.key, $0) }, onCommit: { model.commit(p.label) }).frame(height: 17)
        case .int(let r):
            RecipeScrubber(label: p.label, value: num, range: r, integer: true, driven: driven, onChange: { model.setNumber(id, p.key, $0) }, onCommit: { model.commit(p.label) }).frame(height: 17)
        case .angle:
            RecipeScrubber(label: p.label, value: num, range: -180...180, unit: "°", driven: driven, onChange: { model.setNumber(id, p.key, $0) }, onCommit: { model.commit(p.label) }).frame(height: 17)
        case .seed:
            RecipeScrubber(label: p.label, value: num, range: 0...9999, integer: true, driven: driven, onChange: { model.setNumber(id, p.key, $0) }, onCommit: { model.commit(p.label) }).frame(height: 17)
        case .toggle:
            Button { model.setNumber(id, p.key, num > 0.5 ? 0 : 1); model.commit(p.label) } label: {
                HStack(spacing: 4) {
                    Image(systemName: num > 0.5 ? "checkmark.square.fill" : "square").foregroundStyle(num > 0.5 ? Theme.accent : Theme.textDim)
                    Text(p.label).lineLimit(1)
                    Spacer()
                }.font(Theme.fontSmall).contentShape(Rectangle())
            }.buttonStyle(.plain)
        case .choice(let opts):
            Menu {
                ForEach(Array(opts.enumerated()), id: \.offset) { i, o in
                    Button { model.setNumber(id, p.key, Double(i)); model.commit(p.label) } label: {
                        if i == Int(num) { Label(o, systemImage: "checkmark") } else { Text(o) }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(p.label).foregroundStyle(Theme.textDim).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(opts.indices.contains(Int(num)) ? opts[Int(num)] : "—").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7)).foregroundStyle(Theme.textFaint)
                }
                .font(Theme.fontSmall)
                .padding(.horizontal, 5).frame(height: 17)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain)
        case .color:
            HStack(spacing: 4) {
                Text(p.label).font(Theme.fontSmall).foregroundStyle(driven ? Theme.textFaint : Theme.text).lineLimit(1)
                Spacer()
                if driven { Text("linked").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                else { ColorWell(color: Binding(get: { node.colors[p.key] ?? p.defColor }, set: { model.setColor(id, p.key, $0) }), size: 14, showAlpha: true, onCommit: { model.commit(p.label) }) }
            }
        case .point:
            let v = node.vectors[p.key] ?? p.defPoint
            HStack(spacing: 4) {
                Text(p.label).font(Theme.fontSmall).foregroundStyle(driven ? Theme.textFaint : Theme.text).lineLimit(1)
                Spacer()
                Text(driven ? "linked" : String(format: "%.0f%%, %.0f%%", v.x * 100, v.y * 100)).font(Theme.mono).foregroundStyle(Theme.textDim)
            }
        case .gradient:
            HStack(spacing: 4) {
                Text(p.label).font(Theme.fontSmall).foregroundStyle(driven ? Theme.textFaint : Theme.text).lineLimit(1)
                if driven { Spacer(); Text("linked").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                else { GradientSwatch(gradient: node.gradients[p.key] ?? p.defGradient ?? .twoColor(.black, .white)).frame(height: 12) }
            }
        case .curve:
            HStack { Text(p.label).font(Theme.fontSmall); Spacer(); Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Theme.textDim) }
        case .text, .file:
            let s = node.strings[p.key] ?? ""
            HStack { Text(p.label).font(Theme.fontSmall).foregroundStyle(Theme.textDim); Spacer(); Text(s.isEmpty ? "None" : (s as NSString).lastPathComponent).font(Theme.fontSmall).lineLimit(1).truncationMode(.middle) }
        case .layer:
            let s = node.strings[p.key] ?? ""
            let name = model.document?.state.layer(UUID(uuidString: s))?.name
            HStack { Text("Layer").font(Theme.fontSmall).foregroundStyle(Theme.textDim); Spacer()
                Text(name ?? (s.isEmpty ? (p.label.contains("empty") ? "This Layer" : "Choose…") : "Missing")).font(Theme.fontSmall).foregroundStyle(name == nil && !s.isEmpty ? .orange : Theme.text).lineLimit(1) }
        }
    }
}

// MARK: - Search ("Tab" menu)

struct RecipeSearchPopup: View {
    @Bindable var model: RecipeEditorModel
    @FocusState private var focused: Bool

    var results: [RecipeNodeSpec] {
        guard let s = model.search else { return [] }
        if let w = s.pending {
            return w.fromOutput ? RecipeLibrary.search(s.query, accepting: w.type) : RecipeLibrary.search(s.query, producing: w.type)
        }
        return RecipeLibrary.search(s.query)
    }

    var body: some View {
        let list = results
        let idx = min(model.search?.index ?? 0, max(0, list.count - 1))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("Search nodes…", text: Binding(get: { model.search?.query ?? "" }, set: { model.search?.query = $0; model.search?.index = 0 }))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { pick(list, idx) }
                    .onKeyPress(.downArrow) { model.search?.index = min(idx + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { model.search?.index = max(idx - 1, 0); return .handled }
                    .onKeyPress(.escape) { model.search = nil; return .handled }
            }
            .padding(7)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.type) { i, s in
                            HStack(spacing: 6) {
                                Image(systemName: s.category.symbol).font(.system(size: 9)).foregroundStyle(Color(nsColor: s.category.rgba.nsColor)).frame(width: 14)
                                Text(s.name).lineLimit(1)
                                Spacer()
                                Text(s.group.isEmpty ? s.category.rawValue : s.group).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
                            }
                            .padding(.horizontal, 8).frame(height: 21)
                            .background(i == idx ? Theme.selection : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { pick(list, i) }
                            .id(i)
                        }
                        if list.isEmpty { Text("No matching nodes").foregroundStyle(Theme.textFaint).padding(8) }
                    }
                }
                .onChange(of: idx) { _, v in proxy.scrollTo(v) }
            }
            .frame(height: 270)
        }
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panelBG))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .onAppear { focused = true }
    }

    func pick(_ list: [RecipeNodeSpec], _ i: Int) {
        guard list.indices.contains(i), let s = model.search else { return }
        model.search = nil
        model.addNode(list[i].type, at: s.position, connecting: s.pending)
    }
}
