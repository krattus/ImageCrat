import AppKit
import SwiftUI
import ImageCratCore

// UI of the colour tools: Colour Harmony panel, Palette from Image dialog, Globals / Groups sections of the Swatches
// panel, Recolour Artwork dialog, Contrast Checker panel and the Properties panel additions.

struct SwatchChip: View {
    let color: RGBA
    var size: CGFloat = 20
    var selected = false
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: color.nsColor))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.white : Color(white: 0.25), lineWidth: selected ? 1.5 : 0.5))
            .help("#\(color.hex)")
    }
}

private func pick(_ c: RGBA) {
    let app = AppModel.shared
    if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.option) { app.background = c } else { app.foreground = c }
    app.pushRecent(c)
}

// MARK: - Colour Harmony

/// Hue wheel with the scheme's hues marked. Drag on the ring to turn the base hue.
struct HarmonyWheel: View {
    let base: RGBA
    let scheme: HarmonyScheme
    var onHue: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ring = side * 0.13
            let r = side / 2 - ring / 2 - 2
            let (h, s, v) = base.hsb
            let colors = ColorHarmony.colors(scheme, base: base)
            let hues = scheme == .monochrome ? [h * 360] : ColorHarmony.hues(scheme, baseHue: h * 360)
            ZStack {
                Circle().strokeBorder(AngularGradient(gradient: Gradient(colors: (0...12).map { Color(nsColor: RGBA(h: Double($0) / 12, s: max(0.35, s), v: max(0.6, v)).nsColor) }), center: .center), lineWidth: ring)
                    .frame(width: side - 4, height: side - 4)
                    .position(c)
                // connecting polygon
                Path { p in
                    for (i, hue) in hues.enumerated() {
                        let a = CGFloat(hue * .pi / 180)
                        let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    if hues.count > 2 { p.closeSubpath() } else if hues.count == 1 { p.addLine(to: c) }
                }.stroke(Color.white.opacity(0.7), lineWidth: 1)
                ForEach(Array(hues.enumerated()), id: \.offset) { i, hue in
                    let a = CGFloat(hue * .pi / 180)
                    Circle().fill(Color(nsColor: (i < colors.count ? colors[i] : base).nsColor))
                        .frame(width: i == 0 ? ring + 6 : ring, height: i == 0 ? ring + 6 : ring)
                        .overlay(Circle().stroke(Color.white, lineWidth: i == 0 ? 2 : 1.2))
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .position(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                }
                Circle().fill(Color(nsColor: base.nsColor)).frame(width: side * 0.22, height: side * 0.22).position(c)
                    .overlay(Circle().stroke(Color(white: 0.2), lineWidth: 0.5).frame(width: side * 0.22, height: side * 0.22).position(c))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let d = CGPoint(x: g.location.x - c.x, y: g.location.y - c.y)
                guard d.length > side * 0.2 else { return }
                onHue?(ColorHarmony.normHue(Double(atan2(d.y, d.x)) * 180 / .pi))
            })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct ColorHarmonyPanel: View {
    @Bindable var app = AppModel.shared
    @State private var scheme: HarmonyScheme = .complementary
    @State private var base: RGBA = AppModel.shared.foreground
    /// The last colour this panel put into the foreground (so picking a swatch does not turn the wheel).
    @State private var picked: RGBA?

    var body: some View {
        let keys = ColorHarmony.colors(scheme, base: base)
        let set = ColorHarmony.swatchSet(scheme, base: base)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    HarmonyWheel(base: base, scheme: scheme) { hue in
                        let (_, s, v) = base.hsb
                        base = RGBA(h: hue / 360, s: max(s, 0.05), v: v)
                        picked = base
                        app.foreground = base
                    }
                    .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $scheme) { ForEach(HarmonyScheme.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                        Text("Base #\(base.hex)").font(Theme.mono).foregroundStyle(Theme.textDim)
                        Button("Use Foreground") { base = app.foreground }.buttonStyle(PanelButtonStyle())
                        Text("Click a colour to make it the foreground (⌥-click: background).").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Caption(scheme.title)
                HStack(spacing: 4) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, c in
                        SwatchChip(color: c, size: 30, selected: c.hex == app.foreground.hex).onTapGesture { picked = c; pick(c) }
                    }
                }
                if set.count > keys.count {
                    Caption("Shades and tints")
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 3), count: max(1, keys.count)), alignment: .leading, spacing: 3) {
                        ForEach(Array(set.dropFirst(keys.count).enumerated()), id: \.offset) { _, c in
                            SwatchChip(color: c, size: 22, selected: c.hex == app.foreground.hex).onTapGesture { picked = c; pick(c) }
                        }
                    }
                }
                HStack {
                    Button("Save as Swatch Group") {
                        let g = SwatchGroupStore.shared.add(name: "\(scheme.title) #\(base.hex)", colors: set)
                        app.setStatus("Saved swatch group “\(g.name)” (Swatches panel ▸ Groups)")
                    }.buttonStyle(PanelButtonStyle())
                    Button("Add to Swatches") { PaletteTools.addToSwatches(set) }.buttonStyle(PanelButtonStyle())
                }
            }
            .padding(10)
        }
        .font(Theme.font).foregroundStyle(Theme.text)
        .onChange(of: app.foreground) { _, c in if c != picked { base = c } }
    }
}

// MARK: - Palette from Image

struct PaletteFromImageDialog: View {
    @State private var source: PaletteSource
    @State private var count: Double = 6
    @State private var entries: [PaletteEntry]

    init() {
        let src: PaletteSource = AppActions.doc?.state.selection != nil ? .selection : .document
        _source = State(initialValue: src)
        _entries = State(initialValue: PaletteFromImageDialog.palette(src, 6))
    }

    /// Cached per document revision: the dialog's initial state is rebuilt whenever its host re-renders.
    private static var cache: (key: String, entries: [PaletteEntry])?
    private static func palette(_ source: PaletteSource, _ count: Int) -> [PaletteEntry] {
        guard let d = AppActions.doc else { return [] }
        let key = "\(d.id)|\(d.revision)|\(source.rawValue)|\(count)|\(d.activeLayerID?.uuidString ?? "")"
        if let c = cache, c.key == key { return c.entries }
        let e = PaletteTools.palette(d.state, source: source, activeLayer: d.activeLayerID, count: count)
        cache = (key, e)
        return e
    }

    private func compute() { entries = PaletteFromImageDialog.palette(source, Int(count)) }

    var body: some View {
        let colors = entries.map(\.color)
        DialogFrame(title: "Palette from Image", width: 400, okTitle: "Add to Swatches", onOK: { PaletteTools.addToSwatches(colors) },
                    extraButtons: AnyView(HStack(spacing: 6) {
                        Button("Save as Group") {
                            let g = SwatchGroupStore.shared.add(name: "Palette " + ((AppActions.doc?.name ?? "") as NSString).deletingPathExtension, colors: colors)
                            AppModel.shared.setStatus("Saved swatch group “\(g.name)”")
                            AppModel.shared.dialog = nil
                        }.buttonStyle(PanelButtonStyle())
                        Button("Apply as Gradient Map") {
                            if let d = AppActions.doc { PaletteTools.applyGradientMap(d, colors: colors) }
                            AppModel.shared.dialog = nil
                        }.buttonStyle(PanelButtonStyle()).disabled(colors.count < 2)
                    })) {
            Picker("Source", selection: $source) {
                ForEach(PaletteSource.allCases) { s in Text(s.title).tag(s) }
            }.pickerStyle(.segmented)
            ValueSlider(label: "Colours", value: $count, range: 3...12, step: 1, onCommit: compute)
            PaletteStrip(entries: entries).frame(height: 54)
            Text("k-means clustering in Oklab, sorted dark to light. Bar heights show how much of the image each colour covers.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: source) { _, _ in compute() }
        .onChange(of: count) { _, _ in compute() }
    }
}

struct PaletteStrip: View {
    let entries: [PaletteEntry]
    var body: some View {
        let maxW = entries.map(\.weight).max() ?? 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                VStack(spacing: 2) {
                    Rectangle().fill(Color(nsColor: e.color.nsColor))
                        .frame(height: 12 + 24 * CGFloat(e.weight / max(0.0001, maxW)))
                        .overlay(Rectangle().stroke(Color(white: 0.25), lineWidth: 0.5))
                        .onTapGesture { pick(e.color) }
                    Text(e.color.hex).font(.system(size: 7).monospacedDigit()).foregroundStyle(Theme.textFaint).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .help("#\(e.color.hex) · \(Int((e.weight * 100).rounded()))%")
            }
            if entries.isEmpty { Text("No pixels to analyse").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity) }
        }
    }
}

// MARK: - Swatches panel: Globals and Groups

struct ArtistSwatchSections: View {
    @Bindable var app = AppModel.shared
    @Bindable var store = SwatchGroupStore.shared
    @Bindable var settings = ArtistSettings.shared

    var body: some View {
        if let d = app.activeDocument { GlobalColorsSection(doc: d) }
        if !store.groups.isEmpty {
            Caption("Groups")
            ForEach(store.groups) { g in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(g.name).font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
                        if settings.prefs.paletteJitter != .off && settings.prefs.paletteGroup == g.id {
                            Image(systemName: "paintbrush.pointed").font(.system(size: 8)).foregroundStyle(Theme.accent).help("Used for the brush's colour jitter")
                        }
                        Spacer()
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 3), count: 12), alignment: .leading, spacing: 3) {
                        ForEach(Array(g.colors.enumerated()), id: \.offset) { _, c in SwatchChip(color: c, size: 18).onTapGesture { pick(c) } }
                    }
                }
                .contextMenu {
                    Button("Use for Brush Colour Jitter") {
                        settings.prefs.paletteGroup = g.id
                        if settings.prefs.paletteJitter == .off { settings.prefs.paletteJitter = .perStroke }
                    }
                    Button("Add Colours to Swatches") { PaletteTools.addToSwatches(g.colors) }
                    Button("Delete Group") { store.groups.removeAll { $0.id == g.id } }
                }
            }
        }
    }
}

struct GlobalColorsSection: View {
    @Bindable var doc: Document
    @State private var renaming: UUID?
    @State private var nameDraft = ""

    var body: some View {
        let globals = doc.state.artist.globals
        Caption("Globals")
        if globals.isEmpty {
            Text("Global colours are linked swatches: assign one to shapes, text, fill layers or effects, then edit it to update every use.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(globals) { g in
            HStack(spacing: 6) {
                ColorWell(color: Binding(get: { doc.state.artist.globals.first { $0.id == g.id }?.color ?? g.color },
                                         set: { GlobalColors.setColor(doc, g.id, $0, commit: false) }), size: 16,
                          onCommit: {
                              let now = doc.state.artist.globals.first { $0.id == g.id }?.color
                              let was = doc.committedState.artist.globals.first { $0.id == g.id }?.color
                              if now != was { doc.commit("Edit Global Colour") }
                          })
                if renaming == g.id {
                    TextField("", text: $nameDraft).textFieldStyle(.plain).font(Theme.font)
                        .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                        .onSubmit { GlobalColors.rename(doc, g.id, nameDraft); renaming = nil }
                } else {
                    Text(g.name).lineLimit(1).onTapGesture(count: 2) { nameDraft = g.name; renaming = g.id }
                        .onTapGesture { pick(g.color) }
                }
                Spacer(minLength: 2)
                let n = GlobalColors.usageCount(doc.state, g.id)
                Text(n == 1 ? "1 use" : "\(n) uses").font(Theme.fontSmall).foregroundStyle(n > 0 ? Theme.textDim : Theme.textFaint)
                Menu {
                    assignItems(g)
                    Divider()
                    Button("Set Foreground to This Colour") { pick(g.color) }
                    Button("Update from Foreground") { GlobalColors.setColor(doc, g.id, AppModel.shared.foreground) }
                    Button("Rename…") { nameDraft = g.name; renaming = g.id }
                    Button("Delete Global Colour") { GlobalColors.delete(doc, g.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().menuIndicator(.hidden)
            }
        }
        Button { GlobalColors.add(doc, color: AppModel.shared.foreground) } label: { Label("New Global from Foreground", systemImage: "plus") }
            .buttonStyle(PanelButtonStyle())
    }

    @ViewBuilder func assignItems(_ g: GlobalColor) -> some View {
        if let l = doc.activeLayer {
            let base: [ColorSlot] = l.isShape ? [.shapeFill, .shapeStroke] : l.isText ? [.textColor] : l.isFill ? [.fillLayer] : []
            ForEach(base + [ColorSlot.colorOverlay, .dropShadow, .innerShadow, .outerGlow, .innerGlow, .strokeEffect]) { slot in
                Button("Assign to \(slot.title) of “\(l.name)”") {
                    for id in doc.orderedSelection.isEmpty ? [l.id] : doc.orderedSelection { GlobalColors.assign(doc, layer: id, slot: slot, global: g.id, commit: false) }
                    doc.commit("Assign Global Colour")
                }
            }
        } else {
            Text("Select a layer to assign this colour")
        }
    }
}

// MARK: - Properties panel additions

struct ArtistLayerProperties: View {
    @Bindable var doc: Document
    let layer: Layer

    var body: some View {
        let globals = doc.state.artist.globals
        let slots = GlobalColors.slots(layer)
        if !globals.isEmpty && !slots.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Caption("Global colours")
                ForEach(slots) { slot in
                    let linked = GlobalColors.link(doc.state, layer: layer.id, slot: slot)
                    HStack(spacing: 6) {
                        SwatchChip(color: GlobalColors.color(layer, slot) ?? .black, size: 12)
                        Text(slot.title).foregroundStyle(Theme.textDim)
                        Spacer(minLength: 2)
                        Menu(linked?.name ?? "Not linked") {
                            ForEach(globals) { g in
                                Button(g.name) { GlobalColors.assign(doc, layer: layer.id, slot: slot, global: g.id) }
                            }
                            if linked != nil {
                                Divider()
                                Button("Unlink") { GlobalColors.unlink(doc, layer: layer.id, slot: slot) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
        if layer.isText { ContrastBadgeRow(doc: doc, layerID: layer.id) }
    }
}

/// Compact AA / AAA badge for the Properties panel.
struct ContrastBadgeRow: View {
    @Bindable var doc: Document
    let layerID: UUID

    var body: some View {
        let _ = doc.revision
        if let r = ContrastChecker.cachedReport(doc, layerID: layerID) {
            HStack(spacing: 6) {
                ContrastBadge(level: r.level)
                Text(String(format: "Contrast %.2f : 1", r.worstRatio)).font(Theme.mono)
                Spacer(minLength: 2)
                if let s = r.suggestionAA {
                    Button { ContrastChecker.apply(doc, layerID: layerID, color: s) } label: {
                        HStack(spacing: 3) { SwatchChip(color: s, size: 10); Text("Fix") }
                    }
                    .buttonStyle(PanelButtonStyle()).help("Use the nearest colour that passes AA (#\(s.hex))")
                }
            }
            .help("WCAG contrast of the text against what is beneath it — open Window ▸ Contrast Checker for details")
        }
    }
}

struct ContrastBadge: View {
    let level: WCAG.Level
    var body: some View {
        let color: Color = level == .fail ? Color(red: 0.8, green: 0.2, blue: 0.2) : level == .aaLarge ? Color(red: 0.85, green: 0.55, blue: 0.1) : Color(red: 0.15, green: 0.6, blue: 0.3)
        Text(level.rawValue.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(color))
    }
}

// MARK: - Contrast Checker panel

struct ContrastCheckerPanel: View {
    @Bindable var app = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let d = app.activeDocument, let l = d.activeLayer, l.isText {
                    ContrastDetails(doc: d, layerID: l.id)
                } else {
                    Text("Select a type layer to check its contrast against what is beneath it.").foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Caption("Foreground on background")
                    ManualContrast(a: app.foreground, b: app.background)
                }
                Divider()
                Caption("Simulate (view only)")
                SimulationPicker()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font).foregroundStyle(Theme.text)
    }
}

struct SimulationPicker: View {
    @Bindable var settings = ArtistSettings.shared
    var body: some View {
        Picker("", selection: Binding(get: { settings.simulation }, set: { settings.simulation = $0; ArtistModule.refreshCanvas() })) {
            ForEach(VisionSimulation.allCases) { Text($0.title).tag($0) }
        }.labelsHidden()
    }
}

struct ManualContrast: View {
    let a: RGBA, b: RGBA
    var body: some View {
        let r = WCAG.contrast(a, b)
        HStack(spacing: 8) {
            Text("Aa").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color(nsColor: a.nsColor))
                .frame(width: 54, height: 36).background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: b.nsColor)))
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "%.2f : 1", r)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                HStack(spacing: 4) { ContrastBadge(level: WCAG.level(r, largeText: false)); Text("normal text").foregroundStyle(Theme.textDim) }
            }
        }
    }
}

struct ContrastDetails: View {
    @Bindable var doc: Document
    let layerID: UUID

    var body: some View {
        let _ = doc.revision
        if let r = ContrastChecker.cachedReport(doc, layerID: layerID) {
            HStack(spacing: 8) {
                Text("Aa").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color(nsColor: r.text.nsColor))
                    .frame(width: 60, height: 40)
                    .background(LinearGradient(colors: [Color(nsColor: r.worstBackground.nsColor), Color(nsColor: r.background.nsColor), Color(nsColor: r.bestBackground.nsColor)], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "%.2f : 1", r.worstRatio)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    HStack(spacing: 4) {
                        ContrastBadge(level: r.level)
                        Text(r.largeText ? "large text" : "normal text").foregroundStyle(Theme.textDim)
                    }
                }
            }
            row("Text", r.text)
            row("Beneath (average)", r.background, String(format: "%.2f : 1", r.ratio))
            row("Beneath (worst case)", r.worstBackground, String(format: "%.2f : 1", r.worstRatio))
            Text("AA needs \(r.largeText ? "3" : "4.5") : 1 and AAA \(r.largeText ? "4.5" : "7") : 1 for \(r.largeText ? "large" : "normal") text. The badge uses the worst case beneath the glyphs.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            if r.suggestionAA != nil || r.suggestionAAA != nil {
                Caption("Nearest passing colour")
                if let s = r.suggestionAA { suggestion("AA", s) }
                if let s = r.suggestionAAA { suggestion("AAA", s) }
            } else if r.level == .aaa {
                Label("Passes AAA", systemImage: "checkmark.seal.fill").foregroundStyle(Color(red: 0.3, green: 0.8, blue: 0.45))
            }
        } else {
            Text("The type layer has no visible glyphs on the canvas.").foregroundStyle(Theme.textFaint)
        }
    }

    func row(_ label: String, _ c: RGBA, _ extra: String = "") -> some View {
        HStack(spacing: 6) {
            SwatchChip(color: c, size: 14)
            Text(label).foregroundStyle(Theme.textDim)
            Spacer(minLength: 2)
            Text(extra.isEmpty ? "#\(c.hex)" : extra).font(Theme.mono)
        }
    }

    func suggestion(_ label: String, _ c: RGBA) -> some View {
        HStack(spacing: 6) {
            SwatchChip(color: c, size: 16)
            Text("\(label): #\(c.hex)").font(Theme.mono)
            Spacer(minLength: 2)
            Button("Apply") { ContrastChecker.apply(doc, layerID: layerID, color: c) }.buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - Recolour Artwork

struct RecolorDialog: View {
    @State private var scope: RecolorScope
    @State private var count: Double = 6
    @State private var from: [RGBA]
    @State private var to: [RGBA]
    @State private var preserve = false
    @State private var vector = true
    @State private var raster = true
    @State private var dragging: Int?

    private var doc: Document? { AppActions.doc }

    init() {
        let sc: RecolorScope = (AppActions.doc?.selectedLayerIDs.count ?? 0) > 1 ? .selectedLayers : .document
        let pal = RecolorDialog.palette(sc, 6)
        _scope = State(initialValue: sc)
        _from = State(initialValue: pal)
        _to = State(initialValue: pal)
    }

    /// Cached per committed document revision (the dialog's initial state is rebuilt whenever its host re-renders).
    private static var cache: (key: String, colors: [RGBA])?
    private static func palette(_ scope: RecolorScope, _ count: Int) -> [RGBA] {
        guard let d = AppActions.doc else { return [] }
        let key = "\(d.id)|\(d.revision)|\(scope.rawValue)|\(count)|\(d.selectedLayerIDs.map(\.uuidString).sorted().joined())"
        if let c = cache, c.key == key { return c.colors }
        let p = Recolor.sourcePalette(d.committedState, scope: scope, selected: d.selectedLayerIDs, count: count)
        cache = (key, p)
        return p
    }

    private func extract() {
        from = RecolorDialog.palette(scope, Int(count))
        to = from
        preview()
    }

    /// Live preview: the mapping is applied to the committed state without recording history.
    private func preview() {
        guard let d = doc else { return }
        var st = d.committedState
        Recolor.apply(RecolorMap(from: from, to: to, preserveLuminance: preserve), to: &st, scope: scope, selected: d.selectedLayerIDs, vector: vector, raster: raster)
        d.state = st
    }

    var body: some View {
        DialogFrame(title: "Recolour Artwork", width: 400, okTitle: "Recolour", onOK: {
            preview()
            doc?.commit("Recolour Artwork")
        }, onCancel: { doc?.revertUncommitted() }) {
            Picker("Scope", selection: $scope) { ForEach(RecolorScope.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            ValueSlider(label: "Colours", value: $count, range: 2...12, step: 1, onCommit: extract)
            VStack(spacing: 3) {
                ForEach(Array(from.enumerated()), id: \.offset) { i, c in
                    HStack(spacing: 8) {
                        SwatchChip(color: c, size: 20)
                        Text("#\(c.hex)").font(Theme.mono).foregroundStyle(Theme.textDim).frame(width: 56, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                        if i < to.count {
                            ColorWell(color: Binding(get: { to[i] }, set: { to[i] = $0; preview() }), size: 20)
                                .onDrag { dragging = i; return NSItemProvider(object: "\(i)" as NSString) }
                                .onDrop(of: [.text], isTargeted: nil) { _ in
                                    if let j = dragging, j != i, j < to.count { to.swapAt(i, j); preview() }
                                    dragging = nil
                                    return true
                                }
                            Text("#\(to[i].hex)").font(Theme.mono).frame(width: 56, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        IconButton(symbol: "arrow.uturn.backward", help: "Keep the original colour", size: 18) { if i < to.count { to[i] = from[i]; preview() } }
                    }
                }
                if from.isEmpty { Text("No colours found in scope.").foregroundStyle(Theme.textFaint) }
            }
            HStack(spacing: 6) {
                Menu("Harmony Rule") {
                    ForEach(HarmonyScheme.allCases) { s in
                        Button(s.title + " from the foreground colour") { to = Recolor.harmonyTargets(from, scheme: s, base: AppModel.shared.foreground); preview() }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Button("Rotate") { if to.count > 1 { to.append(to.removeFirst()); preview() } }.buttonStyle(PanelButtonStyle()).help("Shift every new colour to the next row")
                Button("Reset") { to = from; preview() }.buttonStyle(PanelButtonStyle())
            }
            Toggle2(label: "Preserve luminance (only hue and saturation change)", on: Binding(get: { preserve }, set: { preserve = $0; preview() }))
            HStack(spacing: 12) {
                Toggle2(label: "Shapes, type and fills", on: Binding(get: { vector }, set: { vector = $0; preview() }))
                Toggle2(label: "Pixel layers (Colour Lookup adjustment)", on: Binding(get: { raster }, set: { raster = $0; preview() }))
            }
            Text("Drag a new colour onto another row to swap the assignments. Vector, type and fill colours are edited in place; pixel and smart-object layers get a clipped, editable “Recolour” adjustment.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: scope) { _, _ in extract() }
    }
}
