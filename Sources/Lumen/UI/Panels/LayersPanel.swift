import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

struct LayersPanel: View {
    @Bindable var app = AppModel.shared
    @State private var filterText = ""

    var body: some View {
        if let doc = app.activeDocument {
            LayersPanelContent(doc: doc)
        } else {
            Text("No document").font(Theme.font).foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum LayerFilterKind: String, CaseIterable, Identifiable {
    case kind = "Kind", name = "Name", effect = "Effect", mode = "Mode", attribute = "Attribute", color = "Color", artboard = "Artboard"
    var id: String { rawValue }
}

enum LayerKindFilter: String, CaseIterable {
    case pixel = "Pixel", adjustment = "Adjustment", type = "Type", shape = "Shape", smart = "Smart Object"
    var symbol: String {
        switch self {
        case .pixel: return "photo"
        case .adjustment: return "circle.lefthalf.filled"
        case .type: return "textformat"
        case .shape: return "pencil.and.outline"
        case .smart: return "doc.fill"
        }
    }
    func matches(_ l: Layer) -> Bool {
        switch self {
        case .pixel: return l.isRaster
        case .adjustment: return l.isAdjustment || { if case .fill = l.content { return true }; return false }()
        case .type: return l.isText
        case .shape: return l.isShape
        case .smart: return l.isSmartObject
        }
    }
}

struct LayersPanelContent: View {
    @Bindable var doc: Document
    @State private var renaming: UUID?
    @State private var dropTarget: (UUID, Int)?   // id, 0 above / 1 into / 2 below
    @State private var filterOn = false
    @State private var filterKind: LayerFilterKind = .kind
    @State private var kinds: Set<LayerKindFilter> = []
    @State private var filterText = ""
    @State private var filterMode: BlendMode = .normal
    @State private var filterAttr = 0
    @State private var filterColor: LayerColorLabel = .red
    @Environment(\.panelWidth) private var panelWidth

    /// Narrow column: the filter bar's per-kind buttons fold into a menu, the footer's buttons get smaller.
    var narrow: Bool { panelWidth < 290 }
    var compactFooter: Bool { panelWidth < 230 }
    @State private var eyeDrag = EyeDragCoordinator()   // drag across eyes (LayersPanelEyeDrag.swift)

    var filterActive: Bool {
        guard filterOn else { return false }
        switch filterKind {
        case .kind: return !kinds.isEmpty
        case .name: return !filterText.isEmpty
        default: return true
        }
    }

    func passes(_ l: Layer) -> Bool {
        switch filterKind {
        case .kind: return kinds.contains { $0.matches(l) }
        case .name: return l.name.localizedCaseInsensitiveContains(filterText)
        case .effect: return l.effects.hasStyle
        case .mode: return l.blendMode == filterMode
        case .attribute:
            switch filterAttr {
            case 0: return l.isVisible
            case 1: return !l.isVisible
            case 2: return l.locks.anyLocked
            case 3: return l.mask != nil
            case 4: return l.vectorMask != nil
            case 5: return l.isClipped
            case 6: return l.linkID != nil
            default: return l.isSmartObject && (l.smart?.filters.isEmpty == false)
            }
        case .color: return l.colorLabel == filterColor
        case .artboard: return l.isArtboard
        }
    }

    var displayed: [(Layer, Int)] {
        if filterActive {
            return doc.state.layers.flattenedForDisplay(includeCollapsed: true).filter { passes($0.0) }.map { ($0.0, 0) }
        }
        return doc.state.layers.flattenedForDisplay()
    }

    var active: Layer? { doc.activeLayer }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Rectangle().fill(Theme.border).frame(height: 1)
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayed, id: \.0.id) { item in
                            let (layer, depth) = item
                            VStack(spacing: 0) {
                                if layer.isArtboard {   // artboards: top-level header rows with their own menu (Artboards/ArtboardPanels.swift)
                                    ArtboardLayerRow(doc: doc, layer: layer, renaming: $renaming, dropTarget: $dropTarget)
                                } else {
                                    LayerRow(doc: doc, layer: layer, depth: depth, renaming: $renaming, dropTarget: $dropTarget)
                                }
                                // effects stay listed while hidden (master switch or their own eyes): nothing to lose them by
                                if layer.effects.hasStyle && !LayersPanelUI.shared.fxCollapsed.contains(layer.id) {
                                    LayerEffectsRows(doc: doc, layer: layer, depth: depth)
                                }
                            }
                            .id(layer.id)
                        }
                    }
                    .eyeDragColumn(eyeDrag, doc: doc, rows: displayed.map { $0.0.id })
                }
                .onChange(of: LayersPanelUI.shared.reveal?.tick) { _, _ in
                    if let id = LayersPanelUI.shared.reveal?.id { withAnimation(nil) { proxy.scrollTo(id) } }
                }
            }
            .frame(minHeight: 76)   // two rows: in a short group the panel scrolls rather than lose its list
            .background(Theme.panelBG)
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
    }

    // MARK: Filter

    var filterBar: some View {
        HStack(spacing: narrow ? 3 : 4) {
            Picker("", selection: $filterKind) { ForEach(LayerFilterKind.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: narrow ? 66 : 84)
            switch filterKind {
            case .kind where narrow:
                kindMenu
            case .kind:
                ForEach(LayerKindFilter.allCases, id: \.self) { k in
                    IconButton(symbol: k.symbol, help: "Filter for \(k.rawValue) layers", active: kinds.contains(k), size: 20) {
                        if kinds.contains(k) { kinds.remove(k) } else { kinds.insert(k) }
                        filterOn = true
                    }
                }
            case .name:
                TextField("Search", text: $filterText).textFieldStyle(.plain).padding(.horizontal, 4).frame(height: 18)
                    .background(Theme.fieldBG).clipShape(RoundedRectangle(cornerRadius: 3))
                    .onChange(of: filterText) { _, _ in filterOn = true }
            case .mode:
                BlendModePicker(mode: $filterMode, includePassThrough: true, width: narrow ? 64 : 110, onChange: {})
            case .attribute:
                Picker("", selection: $filterAttr) {
                    ForEach(Array(["Visible", "Invisible", "Locked", "Layer Mask", "Vector Mask", "Clipped", "Linked", "Smart Filters"].enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
                }.labelsHidden().frame(width: narrow ? 64 : 110)
            case .color:
                Picker("", selection: $filterColor) { ForEach(LayerColorLabel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().frame(width: narrow ? 64 : 90)
            case .effect, .artboard:
                EmptyView()
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $filterOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().frame(width: 38)   // (its frame is wider than the switch)
                .help("Turn layer filtering on/off")
            panelMenu
        }
        .font(Theme.font)
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    /// The per-kind filter buttons as one menu (narrow columns).
    var kindMenu: some View {
        Menu {
            ForEach(LayerKindFilter.allCases, id: \.self) { k in
                Toggle(k.rawValue, isOn: Binding(get: { kinds.contains(k) }, set: { on in
                    if on { kinds.insert(k) } else { kinds.remove(k) }
                    filterOn = true
                }))
            }
        } label: { Image(systemName: kinds.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
            .menuStyle(.borderlessButton).fixedSize().help("Filter by layer kind")
            .accessibilityLabel("Layer Kinds")
    }

    /// The panel's own menu (Photoshop's flyout): groups and layer styles.
    var panelMenu: some View {
        Menu {
            Button("Collapse All Groups") { LayerGroups.collapseAll(doc) }
            Button("Expand All Groups") { LayerGroups.expandAll(doc) }
            Divider()
            Button("Hide All Effects") { LayerFX.setAllEffects(doc, shown: false) }.disabled(!LayerFX.anyEffectsShown(doc))
            Button("Show All Effects") { LayerFX.setAllEffects(doc, shown: true) }.disabled(!LayerFX.anyEffectsHidden(doc))
            Divider()
            Button("Copy Layer Style") { AppActions.copyLayerStyle() }
            Button("Paste Layer Style") { AppActions.pasteLayerStyle() }.disabled(AppActions.copiedEffects == nil)
            Button("Clear Layer Style") { AppActions.clearLayerStyle() }
        } label: { Image(systemName: "line.3.horizontal") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).help("Layers panel menu")
            .accessibilityLabel("Layers Panel Menu")
    }

    // MARK: Header

    var header: some View {
        VStack(spacing: 6) {
            // (in a narrow column Opacity and Fill wrap under the blend mode and the locks)
            WrappingHStack(spacing: 6) {
                BlendModePicker(mode: Binding(get: { active?.blendMode ?? .normal }, set: { m in
                    AppActions.setBlending(doc) { $0.blendMode = m }
                }), includePassThrough: active?.isGroup ?? false, width: 120, onChange: { commitBlending("Blending Change") })
                .disabled(!blendingEnabled)
                Spacer()
                HStack(spacing: 6) {
                    Text("Opacity:").foregroundStyle(Theme.textDim)
                    PercentScrubber(value: Binding(get: { active?.opacity ?? 1 }, set: { v in
                        AppActions.setBlending(doc) { $0.opacity = v }
                    }), onCommit: { commitBlending("Opacity Change") })
                    .disabled(!blendingEnabled)
                }
            }
            WrappingHStack(spacing: 6) {
                Text("Lock:").foregroundStyle(Theme.textDim)
                lockButton("checkerboard.rectangle", \.transparency, "Lock transparent pixels")
                lockButton("paintbrush", \.pixels, "Lock image pixels")
                lockButton("arrow.up.and.down.and.arrow.left.and.right", \.position, "Lock position")
                lockButton("lock.fill", \.all, "Lock all")
                Spacer()
                HStack(spacing: 6) {
                    Text("Fill:").foregroundStyle(Theme.textDim)
                        .help("Fill fades the layer's own pixels (paint, shape, type, fill) but not its layer effects; Opacity fades both. Without effects they look the same.")
                    PercentScrubber(value: Binding(get: { active?.fillOpacity ?? 1 }, set: { v in
                        AppActions.setBlending(doc) { $0.fillOpacity = v }
                    }), onCommit: { commitBlending("Fill Opacity Change") })
                    .disabled(!blendingEnabled)
                }
            }
        }
        .font(Theme.font)
        .padding(8)
    }

    /// Blend mode / opacity / fill are frozen by Lock All (of the active layer; other locked selected layers are skipped).
    var blendingEnabled: Bool { active.map { !$0.locks.propertiesLocked && !$0.isArtboard } ?? false }   // (artboards have no blending, as in Photoshop)

    func commitBlending(_ name: String) {
        if !AppActions.blendingEditable(doc).isEmpty { doc.commit(name) }
    }

    func lockButton(_ symbol: String, _ kp: WritableKeyPath<LayerLocks, Bool>, _ help: String) -> some View {
        let on = active?.locks[keyPath: kp] ?? false
        return IconButton(symbol: symbol, help: help, active: on, size: 20) { AppActions.setLock(kp) }
    }

    // MARK: Footer

    var footer: some View {
        let icon: CGFloat = compactFooter ? 20 : 22, menu: CGFloat = compactFooter ? 22 : 28   // (8 buttons in 180 pt)
        return HStack(spacing: compactFooter ? 2 : 4) {
            Menu {
                Button("Blending Options / Layer Style…") { if let id = doc.activeLayerID { AppModel.shared.dialog = .layerStyle(id) } }
                Divider()
                ForEach(StyleSection.allCases.filter { $0 != .blending }) { s in
                    Button(s.rawValue + "…") { if let id = doc.activeLayerID { LayerStyleDialog.open(s, layer: id, doc: doc) } }
                }
            } label: { Text("fx").font(.system(size: 12, weight: .bold, design: .serif)).italic() }
                .menuStyle(.borderlessButton).menuIndicator(compactFooter ? .hidden : .visible).frame(width: menu).help("Add a layer style")
            IconButton(symbol: "circle.rectangle.filled.pattern.diagonalline", help: "Add layer mask", size: icon) {
                AppActions.addMask(doc.state.selection != nil ? .revealSelection : .revealAll)
            }
            Menu {
                Button("Solid Color…") { FillLayerDialog.newLayer(.solid) }
                Button("Gradient…") { FillLayerDialog.newLayer(.gradient) }
                Button("Pattern…") { FillLayerDialog.newLayer(.pattern) }
                Divider()
                ForEach(AdjustmentKind.layerKinds) { k in Button(k.displayName + "…") { AppActions.newAdjustmentLayer(k) } }
            } label: { Image(systemName: "circle.lefthalf.filled") }
                .menuStyle(.borderlessButton).menuIndicator(compactFooter ? .hidden : .visible).frame(width: menu).help("Create new fill or adjustment layer")
            Menu {
                Button("Place Embedded…") { AppActions.placePanel(linked: false) }
                Button("Place Linked…") { AppActions.placePanel(linked: true) }
            } label: { Image(systemName: "photo.badge.plus") }
                .menuStyle(.borderlessButton).menuIndicator(compactFooter ? .hidden : .visible).frame(width: menu).help("Place an image (embedded or linked)")
            IconButton(symbol: "link", help: "Link layers", active: (active?.linkID != nil), size: icon) { AppActions.toggleLinkLayers() }
            IconButton(symbol: "folder", help: "Create a new group", size: icon) { AppActions.newGroup() }
            IconButton(symbol: "plus.square", help: "Create a new layer", size: icon) { AppActions.newLayer() }
            IconButton(symbol: "trash", help: "Delete layer", size: icon) {
                if doc.editTarget == .mask { AppActions.deleteMask() } else { AppActions.deleteLayers() }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Theme.panelHeader)
    }
}

/// Click-and-drag percent control (like Photoshop's scrubby sliders).
struct PercentScrubber: View {
    @Binding var value: Double
    var onCommit: () -> Void
    @State private var open = false
    @State private var dragStart: Double?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            Text("\(Int((value * 100).rounded()))%").font(Theme.mono).frame(width: 34, alignment: .trailing)
            Image(systemName: "chevron.down").font(.system(size: 7))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        .opacity(isEnabled ? 1 : 0.4)
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            if dragStart == nil { dragStart = value }
            value = clamp((dragStart ?? value) + Double(v.translation.width) / 200, 0, 1)
        }.onEnded { _ in dragStart = nil; onCommit() })
        .onTapGesture { open = true }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Slider(value: $value, in: 0...1, onEditingChanged: { if !$0 { onCommit() } }).frame(width: 160).padding(10)
        }
    }
}

struct LayerRow: View {
    @Bindable var doc: Document
    let layer: Layer
    let depth: Int
    @Binding var renaming: UUID?
    @Binding var dropTarget: (UUID, Int)?
    @State private var nameText = ""
    @State private var hover = false

    var selected: Bool { doc.selectedLayerIDs.contains(layer.id) }
    var isActive: Bool { doc.activeLayerID == layer.id }

    var body: some View {
        HStack(spacing: 4) {
            // Visibility
            // (mouse clicks and drags on the eye column go to the list's EyeColumnView; the button is the accessible eye)
            Button {
                EyeVisibility.press(doc, .layer(layer.id))
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? Theme.text : Theme.textFaint)
                    .frame(width: 22, height: 36)
            }.buttonStyle(.plain)
            .accessibilityLabel((layer.isVisible ? "Hide " : "Show ") + layer.name)
            Rectangle().fill(Theme.border).frame(width: 1)
            Spacer().frame(width: CGFloat(depth) * 14)
            if layer.isGroup {
                // The whole row height is the target; a view-only change (no history step, not undone, saved with the
                // document) that doesn't select the group. ⌥-click opens / closes every group inside it too.
                Button {
                    LayerGroups.toggle(doc, layer.id, recursive: NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: layer.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textDim)
                        .frame(width: LayerRow.disclosureWidth, height: 38).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel(layer.isExpanded ? "Collapse Group" : "Expand Group")
                .help("Expand / collapse the group (⌥-click: nested groups too)")
            }
            if layer.isClipped {
                Image(systemName: "arrow.turn.left.down").font(.system(size: 9)).foregroundStyle(Theme.textDim)
            }
            thumbnail
            if layer.mask != nil { maskThumbnail }
            if layer.vectorMask != nil {
                Image(systemName: "pencil.and.outline").font(.system(size: 10)).foregroundStyle(Theme.textDim).frame(width: 18)
            }
            nameView
            Spacer(minLength: 2)
            badges
        }
        .padding(.trailing, 6)
        .frame(height: 38)
        .eyeRow(.layer(layer.id))
        .background(selected ? Theme.selection.opacity(isActive ? 1 : 0.6) : (hover ? Theme.hover.opacity(0.5) : Color.clear))
        .overlay(dropIndicator, alignment: .top)
        .overlay(Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1), alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // (clicks on the eye or the disclosure triangle don't select the layer: they act on their own)
        .gesture(SpatialTapGesture(count: 2).onEnded { if !inControl($0.location.x) { doubleClick() } })
        .simultaneousGesture(SpatialTapGesture().onEnded { if !inControl($0.location.x) { click() } })
        .onDrag { NSItemProvider(object: layer.id.uuidString as NSString) }
        .onDrop(of: [.text], delegate: LayerDropDelegate(target: layer, doc: doc, dropTarget: $dropTarget))
        .contextMenu { contextMenu }
    }

    static let disclosureWidth: CGFloat = 16

    /// Whether row x position `x` falls on the eye column or the group's disclosure triangle.
    func inControl(_ x: CGFloat) -> Bool { LayerRow.inControl(x, isGroup: layer.isGroup, depth: depth) }

    static func inControl(_ x: CGFloat, isGroup: Bool, depth: Int) -> Bool {
        if x < 27 { return true }                              // eye (22) + spacing + divider
        guard isGroup else { return false }
        let start = 31 + CGFloat(depth) * 14                   // eye, divider, indent (HStack spacing 4)
        return x >= start - 2 && x <= start + disclosureWidth + 2
    }

    @ViewBuilder var dropIndicator: some View {
        if let (id, pos) = dropTarget, id == layer.id {
            if pos == 1 {
                RoundedRectangle(cornerRadius: 2).stroke(Theme.accent, lineWidth: 2).frame(height: 38)
            } else {
                Rectangle().fill(Theme.accent).frame(height: 2).offset(y: pos == 0 ? 0 : 36)
            }
        }
    }

    var thumbnail: some View {
        ZStack {
            if layer.isAdjustment, let a = layer.adjustment {
                RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)
                Image(systemName: a.kind.symbol).font(.system(size: 13)).foregroundStyle(Theme.text)
            } else if layer.isArtboard {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 15)).foregroundStyle(Theme.text)
            } else if layer.isGroup {
                Image(systemName: layer.isExpanded ? "folder" : "folder.fill").font(.system(size: 16)).foregroundStyle(Theme.textDim)
            } else if case .fill(let f) = layer.content, f.recipe == nil {
                PaintStyleSwatch(paint: f.paint)
            } else {
                CheckerBackground(size: 3)
                if let img = Thumbnails.shared.layer(layer, doc: doc, size: 30) {
                    Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit)
                }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(isActive && doc.editTarget == .content && layer.mask != nil ? Color.white : Color(white: 0.3), lineWidth: isActive && doc.editTarget == .content && layer.mask != nil ? 1.5 : 0.5))
        .overlay(alignment: .bottomTrailing) { kindBadge }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                AppActions.selectLayerPixels(layer.id, mode: NSEvent.modifierFlags.contains(.shift) ? .add : .new)
            } else {
                doc.selectLayer(layer.id)
                doc.editTarget = .content
            }
        }
    }

    /// Corner badge identifying smart objects, type and shape layers (drawn above the thumbnail, not clipped).
    @ViewBuilder var kindBadge: some View {
        if layer.isSmartObject {
            LayerKindBadge(symbol: layer.smart?.linkedURL != nil ? "link" : "doc.fill", help: layer.smart?.linkedURL != nil ? "Linked Smart Object" : "Smart Object")
        } else if layer.isText {
            LayerKindBadge(symbol: "textformat", help: "Type Layer")
        } else if layer.isShape {
            LayerKindBadge(symbol: "pencil.and.outline", help: "Shape Layer")
        }
    }

    var maskThumbnail: some View {
        ZStack {
            if let img = Thumbnails.shared.mask(layer, doc: doc, size: 30) {
                Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit)
            }
            if layer.mask?.isEnabled == false {
                Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 30, y: 30)); p.move(to: CGPoint(x: 30, y: 0)); p.addLine(to: CGPoint(x: 0, y: 30)) }
                    .stroke(Color.red, lineWidth: 2)
            }
        }
        .frame(width: 30, height: 30)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(isActive && doc.editTarget == .mask ? Color.white : Color(white: 0.3), lineWidth: isActive && doc.editTarget == .mask ? 1.5 : 0.5))
        .onTapGesture {
            let f = NSEvent.modifierFlags
            if f.contains(.shift) { doc.selectLayer(layer.id); AppActions.toggleMaskEnabled(); return }
            if f.contains(.command), let m = layer.mask {
                doc.setSelection(SelectionOps.fromAlpha(m.buffer, origin: m.origin, width: doc.state.width, height: doc.state.height), commitName: "Load Selection")
                return
            }
            doc.selectLayer(layer.id)
            doc.editTarget = .mask
        }
    }

    @ViewBuilder var nameView: some View {
        if renaming == layer.id {
            TextField("", text: $nameText)
                .textFieldStyle(.plain)
                .font(Theme.font)
                .padding(2)
                .background(Theme.fieldBG)
                .onSubmit { finishRename() }
                .onAppear { nameText = layer.name }
                .onExitCommand { renaming = nil }
        } else {
            Text(layer.name)
                .font(Theme.font)
                .foregroundStyle(layer.isVisible ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .gesture(TapGesture(count: 2).onEnded { renaming = layer.id })
        }
    }

    @ViewBuilder var badges: some View {
        if case .text(let t) = layer.content, let note = t.missingFontNote {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Color.yellow).help(note)
        }
        GenLayerBadge(doc: doc, layerID: layer.id)
        ComponentLayerBadge(layer: layer)
        if layer.linkID != nil {
            Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Theme.textDim).help("Linked layer")
        }
        if let c = layer.colorLabel.rgba {
            Circle().fill(Color(nsColor: c.nsColor)).frame(width: 7, height: 7)
        }
        if layer.locks.anyLocked {
            Image(systemName: layer.locks.all ? "lock.fill" : "lock").font(.system(size: 9)).foregroundStyle(Theme.textDim)
        }
        if layer.effects.hasStyle {
            let open = !LayersPanelUI.shared.fxCollapsed.contains(layer.id)
            HStack(spacing: 1) {
                Text("fx").font(.system(size: 10, weight: .bold, design: .serif)).italic()
                    .foregroundStyle(layer.effects.enabled && layer.effects.shownCount > 0 ? Theme.text : Theme.textFaint)
                    .onTapGesture { AppModel.shared.dialog = .layerStyle(layer.id) }
                    .help("Layer Style…")
                Button {
                    if open { LayersPanelUI.shared.fxCollapsed.insert(layer.id) } else { LayersPanelUI.shared.fxCollapsed.remove(layer.id) }
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textDim)
                        .frame(width: 12, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel(open ? "Collapse Effects" : "Expand Effects")
                .help(open ? "Hide the list of effects" : "Show the list of effects")
            }
        }
        if case .smartObject(let so) = layer.content, !so.filters.isEmpty {
            Image(systemName: "camera.filters").font(.system(size: 9)).foregroundStyle(Theme.textDim)
        }
    }

    func click() {
        let f = NSEvent.modifierFlags
        doc.selectLayer(layer.id, extend: f.contains(.command), range: f.contains(.shift))
        if doc.editTarget == .mask && layer.mask == nil { doc.editTarget = .content }
    }

    func doubleClick() {
        switch layer.content {
        case .smartObject: AppActions.editSmartContents(layer.id)
        case .adjustment: doc.selectLayer(layer.id)
        case .fill(let f) where f.recipe != nil: RecipeActions.openEditor(.layer(layer.id))
        case .fill: FillLayerDialog.open(layer.id)   // Color / Gradient / Pattern Fill dialog
        case .text:
            doc.selectLayer(layer.id)
            AppModel.shared.tool = .text
            if let tt = AppActions.canvas?.tool(for: .text) as? TextTool { tt.beginEditing(layer.id, isNew: false) }
        default: AppModel.shared.dialog = .layerStyle(layer.id)
        }
    }

    func finishRename() {
        let n = nameText.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty && n != layer.name {
            doc.updateLayer(layer.id) { $0.name = n }
            doc.commit("Rename Layer")
        }
        renaming = nil
    }

    @ViewBuilder var contextMenu: some View {
        GenLayerContextMenu(doc: doc, layerID: layer.id)
        AssistLayerContextMenu(doc: doc, layerID: layer.id)
        ComponentLayerContextMenu(doc: doc, layerID: layer.id)
        Button("Layer Style…") { AppModel.shared.dialog = .layerStyle(layer.id) }
        Divider()
        Button("Duplicate Layer") { doc.selectLayer(layer.id); AppActions.duplicateLayers() }
        Button("Delete Layer") { doc.selectLayer(layer.id); AppActions.deleteLayers() }
        Button("Rename Layer") { renaming = layer.id }
        if doc.orderedSelection.count > 1 {
            Button("Rename \(doc.orderedSelection.count) Layers…") { DialogRegistry.show("batchRename") }
            Button("Arrange on Shape…") { DialogRegistry.show("arrangeOnShape") }
        }
        Divider()
        Button("Group from Layers") { AppActions.groupLayers() }.disabled(AppActions.selectionHasArtboard(doc))   // (artboards can't be grouped)
        ArtboardLayerMenuItems(doc: doc, layer: layer)
        Button(layer.linkID != nil && doc.orderedSelection.count <= 1 ? "Unlink Layers" : "Link Layers") { AppActions.toggleLinkLayers() }
        if layer.linkID != nil { Button("Select Linked Layers") { doc.selectLayer(layer.id); AppActions.selectLinkedLayers() } }
        if layer.isGroup { Button("Ungroup") { doc.selectLayer(layer.id); AppActions.ungroupLayers() } }
        Divider()
        Button("Convert to Smart Object") { AppActions.convertToSmartObject() }
        if layer.isSmartObject {
            Button("Edit Contents") { AppActions.editSmartContents(layer.id) }
            Button("Replace Contents…") { AppActions.replaceSmartContents() }
            Button("Export Contents…") { AppActions.exportSmartContents() }
            if let so = layer.smart {
                let sc = AppActions.smartObjectScale(so)
                Button("Reset to Original Size (now \(Int((sc.x * 100).rounded()))%)") { doc.selectLayer(layer.id); AppActions.resetSmartObject([layer.id], keepRotation: true) }
                Button("Reset Transform") { doc.selectLayer(layer.id); AppActions.resetSmartObject([layer.id], keepRotation: false) }
            }
            if layer.smart?.linkedURL != nil {
                Button("Update Modified Content") { AppActions.updateModifiedLinkedContent(doc, all: true) }
                Button("Relink to File…") { doc.selectLayer(layer.id); AppActions.relinkToFile() }
                Button("Embed Linked") { doc.selectLayer(layer.id); AppActions.embedLinked() }
            } else {
                Button("Convert to Linked…") { doc.selectLayer(layer.id); AppActions.convertToLinked() }
            }
        }
        if !layer.isRaster && !layer.isAdjustment { Button("Rasterize Layer") { AppActions.rasterizeLayer(layer.id) } }
        if layer.effects.hasStyle { Button("Rasterize Layer Style") { doc.selectLayer(layer.id); AppActions.rasterizeLayerStyle() } }
        if layer.isText {
            Button("Convert to Shape") { doc.selectLayer(layer.id); AppActions.convertTextToShape() }
            Button("Create Work Path") { doc.selectLayer(layer.id); AppActions.createWorkPathFromText() }
        }
        Divider()
        if layer.mask == nil {
            Button("Add Layer Mask") { doc.selectLayer(layer.id); AppActions.addMask(.revealAll) }
        } else {
            Button(layer.mask!.isEnabled ? "Disable Layer Mask" : "Enable Layer Mask") { doc.selectLayer(layer.id); AppActions.toggleMaskEnabled() }
            Button("Apply Layer Mask") { doc.selectLayer(layer.id); AppActions.applyMask() }
            Button("Delete Layer Mask") { doc.selectLayer(layer.id); AppActions.deleteMask() }
        }
        Button(layer.isClipped ? "Release Clipping Mask" : "Create Clipping Mask") { doc.selectLayer(layer.id); AppActions.toggleClippingMask() }
        Divider()
        Button("Copy Layer Style") { doc.selectLayer(layer.id); AppActions.copyLayerStyle() }
        Button("Paste Layer Style") { doc.selectLayer(layer.id); AppActions.pasteLayerStyle() }
        Button("Clear Layer Style") { doc.selectLayer(layer.id); AppActions.clearLayerStyle() }
        Divider()
        Button("Merge Down") { doc.selectLayer(layer.id); AppActions.mergeDown() }
        Button("Merge Visible") { AppActions.mergeVisible() }
        Button("Flatten Image") { AppActions.flattenImage() }
        Divider()
        Menu("Color Label") {
            ForEach(LayerColorLabel.allCases, id: \.self) { c in
                Button(c.rawValue.capitalized) { doc.updateLayer(layer.id) { $0.colorLabel = c }; doc.commit("Color Label") }
            }
        }
    }
}

struct LayerDropDelegate: DropDelegate {
    let target: Layer
    let doc: Document
    @Binding var dropTarget: (UUID, Int)?

    func position(_ info: DropInfo) -> Int {
        let y = info.location.y
        if target.isGroup && y > 10 && y < 28 { return 1 }
        return y < 19 ? 0 : 2
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTarget = (target.id, position(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { if dropTarget?.0 == target.id { dropTarget = nil } }

    func performDrop(info: DropInfo) -> Bool {
        let pos = position(info)
        dropTarget = nil
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let id = UUID(uuidString: s) else { return }
            DispatchQueue.main.async {
                // ⌥-drag duplicates the layer to the drop position (like Photoshop)
                if NSEvent.modifierFlags.contains(.option), let d = AppActions.doc, let src = d.state.layer(id) {
                    let copy = src.duplicated(newName: src.name + " copy")
                    d.state.insertLayer(copy, above: id)
                    AppActions.moveLayer(copy.id, relativeTo: target.id, above: pos == 0, into: pos == 1)
                    d.selectLayer(copy.id)
                    return
                }
                AppActions.moveLayer(id, relativeTo: target.id, above: pos == 0, into: pos == 1)
            }
        }
        return true
    }
}

/// Small white chip in a thumbnail's corner, like Photoshop's smart object indicator.
struct LayerKindBadge: View {
    let symbol: String
    var help: String = ""
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color(white: 0.15))
            .frame(width: 12, height: 12)
            .background(RoundedRectangle(cornerRadius: 2.5).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Color(white: 0.1), lineWidth: 0.75))
            .offset(x: 2, y: 2)
            .help(help)
    }
}
