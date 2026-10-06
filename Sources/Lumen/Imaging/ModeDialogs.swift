import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageCratCore

/// Shared dialog chrome.
struct ImagingDialogFrame<Content: View>: View {
    let title: String
    var width: CGFloat = 440
    var okTitle = "OK"
    var okDisabled = false
    let onOK: () -> Void
    var onCancel: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(title)).font(.system(size: 13, weight: .semibold))
            content
            HStack {
                Spacer()
                Button("Cancel") { onCancel?(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button(tr(okTitle)) { FieldEdits.commit(); onOK() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(okDisabled)
            }
        }
        .font(Theme.font)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: width)
    }
}

// MARK: - Bitmap

struct BitmapDialog: View {
    @State private var o = BitmapOptions(outputResolution: AppActions.doc?.state.resolution ?? 72)
    var body: some View {
        let inRes = AppActions.doc?.state.resolution ?? 72
        ImagingDialogFrame(title: "Bitmap", onOK: {
            AppModel.shared.dialog = nil
            if let d = AppActions.doc { ColorModes.convertToBitmap(d, o) }
        }) {
            Caption("Resolution")
            Text("Input: \(Int(inRes)) Pixels/Inch").foregroundStyle(Theme.textDim)
            ValueSlider(label: "Output", value: $o.outputResolution, range: 10...1200, unit: "ppi", labelWidth: 60)
            Caption("Method")
            Picker("Use", selection: $o.method) { ForEach(BitmapMethod.allCases) { Text(tr($0.rawValue)).tag($0) } }
            if o.method == .halftone {
                ValueSlider(label: "Frequency", value: $o.frequency, range: 1...400, unit: "lpi", labelWidth: 70)
                ValueSlider(label: "Angle", value: $o.angle, range: -180...180, unit: "°", labelWidth: 70)
                Picker("Shape", selection: $o.shape) { ForEach(HalftoneShape.allCases) { Text(tr($0.rawValue)).tag($0) } }
            }
            if o.method == .custom {
                Picker("Pattern", selection: $o.patternID) {
                    ForEach(PatternDef.builtIn + AppModel.shared.customPatterns) { Text(tr($0.name)).tag($0.id) }
                }
            }
            if let d = AppActions.doc, d.state.layers.count > 1 {
                Text("The image will be flattened.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

// MARK: - Indexed Color

struct IndexedColorDialog: View {
    @State private var o = IndexedDialogState.last
    @State private var preview = true
    @State private var info = ""
    @State private var pending: DispatchWorkItem?

    var body: some View {
        ImagingDialogFrame(title: "Indexed Color", onOK: {
            AppModel.shared.dialog = nil
            IndexedDialogState.last = o
            guard let d = AppActions.doc else { return }
            d.displayOverride = nil
            ColorModes.convertToIndexed(d, o)
        }, onCancel: { AppActions.doc?.displayOverride = nil; AppActions.doc?.setNeedsRender() }) {
            Picker("Palette", selection: $o.palette) { ForEach(PaletteKind.allCases) { Text(tr($0.rawValue)).tag($0) } }
            if o.palette == .custom {
                HStack {
                    Text("\((o.custom ?? []).count) colours").foregroundStyle(Theme.textDim)
                    Button("Load Table…") { loadCustom() }.buttonStyle(PanelButtonStyle())
                    Button("Use Swatches") { o.custom = Array(AppModel.shared.swatches.prefix(256)) }.buttonStyle(PanelButtonStyle())
                }
            }
            if o.palette.usesCount || o.palette == .exact {
                ValueSlider(label: "Colors", value: Binding(get: { Double(o.colors) }, set: { o.colors = Int($0) }), range: 2...256, step: 1, labelWidth: 70)
                    .disabled(o.palette == .exact)
            }
            Picker("Forced", selection: $o.forced) { ForEach(ForcedColors.allCases) { Text(tr($0.rawValue)).tag($0) } }
            HStack {
                Toggle2(label: "Transparency", on: $o.transparency)
                Spacer()
                Text("Matte").foregroundStyle(Theme.textDim)
                ColorWell(color: $o.matte, size: 18)
            }
            Caption("Options")
            Picker("Dither", selection: $o.dither) { ForEach(DitherKind.allCases) { Text(tr($0.rawValue)).tag($0) } }
            if o.dither != .none {
                ValueSlider(label: "Amount", value: Binding(get: { o.amount * 100 }, set: { o.amount = $0 / 100 }), range: 1...100, unit: "%", labelWidth: 70)
                Toggle2(label: "Preserve Exact Colors", on: $o.preserveExact)
            }
            HStack {
                Toggle2(label: "Preview", on: $preview)
                Spacer()
                Text(tr(info)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
        .onAppear { schedule() }
        .onChange(of: o) { _, _ in schedule() }
        .onChange(of: preview) { _, _ in schedule() }
    }

    func schedule() {
        pending?.cancel()
        guard let d = AppActions.doc else { return }
        guard preview else { d.displayOverride = nil; d.setNeedsRender(); return }
        let opts = o
        let w = DispatchWorkItem {
            let st = ColorModes.indexed(d.state, opts)
            let img = Compositor.shared.composite(st)
            d.displayOverride = { _ in img }
            info = "\(st.imaging?.colorTable?.count ?? 0) colours"
            d.setNeedsRender()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func loadCustom() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["act", "aco", "ase"].compactMap { UTType(filenameExtension: $0) }
        UIBlock.begin(p) { r in
            guard r == .OK, let u = p.url else { return }
            if u.pathExtension.lowercased() == "act", let d = try? Data(contentsOf: u) { o.custom = SwatchIO.parseACT(d) }
            else if let lib = try? SwatchIO.load(url: u) { o.custom = Array(lib.colors.map(\.color).prefix(256)) }
        }
    }
}

enum IndexedDialogState { static var last = IndexedOptions() }

// MARK: - Color Table

struct ColorTableDialog: View {
    @State private var table: [RGBA] = AppActions.doc?.state.imaging?.colorTable ?? []
    @State private var transparent: Int? = AppActions.doc?.state.imaging?.transparentIndex
    @State private var selected: Int?
    @State private var editColor: RGBA = .black

    var body: some View {
        ImagingDialogFrame(title: "Color Table", width: 400, onOK: {
            AppModel.shared.dialog = nil
            if let d = AppActions.doc { ColorModes.applyColorTable(d, table, transparentIndex: transparent) }
        }) {
            Picker("Table", selection: Binding(get: { "Custom" }, set: { v in applyPreset(v) })) {
                ForEach(["Custom", "Black Body", "Grayscale", "Spectrum", "System (Mac OS)", "System (Windows)", "Web"], id: \.self) { Text(tr($0)).tag($0) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(15), spacing: 2), count: 16), spacing: 2) {
                ForEach(Array(table.enumerated()), id: \.offset) { i, c in
                    ZStack {
                        if i == transparent { CheckerBackground(size: 4) } else { Rectangle().fill(Color(nsColor: c.withAlpha(1).nsColor)) }
                    }
                    .frame(width: 15, height: 15)
                    .overlay(Rectangle().stroke(selected == i ? Color.white : Color(white: 0.3), lineWidth: selected == i ? 2 : 0.5))
                    .onTapGesture { selected = i; editColor = c.withAlpha(1) }
                    .help("\(i): #\(c.hex)")
                }
            }
            if let s = selected, s < table.count {
                HStack {
                    Text("Entry \(s)").foregroundStyle(Theme.textDim)
                    ColorWell(color: Binding(get: { editColor }, set: { editColor = $0; table[s] = $0.withAlpha(1) }), size: 18)
                    Spacer()
                    Button(tr(transparent == s ? "Opaque" : "Make Transparent")) { transparent = transparent == s ? nil : s }.buttonStyle(PanelButtonStyle())
                }
            }
            HStack {
                Button("Load…") { load() }.buttonStyle(PanelButtonStyle())
                Button("Save…") { save() }.buttonStyle(PanelButtonStyle())
                Spacer()
                Text("\(table.count) colours").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }

    func applyPreset(_ name: String) {
        let n = max(2, table.count)
        switch name {
        case "Black Body":
            table = (0..<n).map { i in let t = Double(i) / Double(n - 1); return RGBA(r: clamp(t * 3, 0, 1), g: clamp(t * 3 - 1, 0, 1), b: clamp(t * 3 - 2, 0, 1)) }
        case "Grayscale": table = (0..<n).map { RGBA(gray: Double($0) / Double(n - 1)) }
        case "Spectrum": table = (0..<n).map { RGBA(h: Double($0) / Double(n), s: 1, v: 1) }
        case "System (Mac OS)": table = Palettes.systemMac
        case "System (Windows)": table = Palettes.systemWindows
        case "Web": table = Palettes.web
        default: break
        }
        if let t = transparent, t >= table.count { transparent = nil }
    }

    func load() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["act", "aco", "ase"].compactMap { UTType(filenameExtension: $0) }
        UIBlock.begin(p) { r in
            guard r == .OK, let u = p.url else { return }
            if u.pathExtension.lowercased() == "act", let d = try? Data(contentsOf: u) { table = SwatchIO.parseACT(d) }
            else if let lib = try? SwatchIO.load(url: u) { table = Array(lib.colors.map(\.color).prefix(256)) }
        }
    }

    func save() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "act") ?? .data]
        p.nameFieldStringValue = "Color Table.act"
        UIBlock.begin(p) { r in
            guard r == .OK, let u = p.url else { return }
            try? SwatchIO.writeACT(table, transparentIndex: transparent).write(to: u)
        }
    }
}

// MARK: - Duotone

struct DuotoneDialog: View {
    @State private var s: DuotoneSettings = AppActions.doc?.state.imaging?.duotone ?? DuotoneSettings.presets[1].1
    @State private var editing: Int? = nil
    @State private var preview = true

    var body: some View {
        ImagingDialogFrame(title: "Duotone Options", width: 460, onOK: {
            AppModel.shared.dialog = nil
            guard let d = AppActions.doc else { return }
            d.displayOverride = nil
            ColorModes.convertToDuotone(d, s)
        }, onCancel: { AppActions.doc?.displayOverride = nil; AppActions.doc?.setNeedsRender() }) {
            HStack {
                Picker("Preset", selection: Binding(get: { "" }, set: { n in if let p = DuotoneSettings.presets.first(where: { $0.0 == n }) { s = p.1 } })) {
                    Text("Custom").tag("")
                    ForEach(DuotoneSettings.presets, id: \.0) { Text(tr($0.0)).tag($0.0) }
                }
            }
            Picker("Type", selection: Binding(get: { s.type }, set: { setType($0) })) { ForEach(DuotoneType.allCases) { Text(tr($0.name)).tag($0) } }
            ForEach(Array(s.inks.enumerated()), id: \.element.id) { i, ink in
                HStack(spacing: 8) {
                    Text("Ink \(i + 1):").foregroundStyle(Theme.textDim).frame(width: 44, alignment: .leading)
                    Button { editing = editing == i ? nil : i } label: {
                        CurveThumb(curve: ink.curve).frame(width: 34, height: 26)
                    }.buttonStyle(.plain).help("Duotone curve")
                    ColorWell(color: Binding(get: { s.inks[i].color }, set: { s.inks[i].color = $0 }), size: 18)
                    TextField("", text: Binding(get: { s.inks[i].name }, set: { s.inks[i].name = $0 })).textFieldStyle(.plain).padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)).frame(width: 150)
                }
                if editing == i {
                    CurveEditor(curve: Binding(get: { s.inks[i].curve }, set: { s.inks[i].curve = $0 }), hist: nil, channel: 0, color: Color(nsColor: ink.color.nsColor), onCommit: {})
                        .frame(width: 200, height: 160)
                }
            }
            DuotoneRamp(s: s).frame(height: 14)
            Toggle2(label: "Preview", on: $preview)
        }
        .onAppear { updatePreview() }
        .onChange(of: s) { _, _ in updatePreview() }
        .onChange(of: preview) { _, _ in updatePreview() }
    }

    func setType(_ t: DuotoneType) {
        let defaults: [DuotoneInk] = [DuotoneInk(name: "Black", color: .black), DuotoneInk(name: "Ink 2", color: RGBA(hex: "A0652A")!),
                                      DuotoneInk(name: "Ink 3", color: RGBA(hex: "E08A2E")!), DuotoneInk(name: "Ink 4", color: RGBA(hex: "4A5A70")!)]
        var inks = Array(s.inks.prefix(t.rawValue))
        while inks.count < t.rawValue { inks.append(defaults[inks.count]) }
        s.inks = inks
    }

    func updatePreview() {
        guard let d = AppActions.doc else { return }
        if preview {
            let settings = s
            let alreadyDuo = d.state.colorMode == .duotone
            d.displayOverride = { img in
                // In duotone mode the canvas hook also applies the stored settings; preview replaces the gray source.
                let g = alreadyDuo ? Compositor.shared.composite(d) : AdjustmentEngine.apply(AdjustmentSettings(kind: .desaturate), to: img)
                return ImagingDisplay.duotone(g, settings)
            }
        } else { d.displayOverride = nil }
        d.setNeedsRender()
    }
}

struct CurveThumb: View {
    let curve: CurvePoints
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.95)))
            let lut = curve.lut(32)
            var p = Path()
            for (i, v) in lut.enumerated() {
                let pt = CGPoint(x: CGFloat(i) / 31 * size.width, y: (1 - v) * size.height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(.black), lineWidth: 1)
        }
        .overlay(Rectangle().stroke(Color(white: 0.4), lineWidth: 0.5))
    }
}

struct DuotoneRamp: View {
    let s: DuotoneSettings
    var body: some View {
        Canvas { ctx, size in
            let luts = s.inks.map { $0.curve.lut(256) }
            let n = Int(size.width)
            for x in 0..<max(1, n) {
                let c = s.color(forGray: 1 - Double(x) / Double(max(1, n - 1)), luts: luts)
                ctx.fill(Path(CGRect(x: CGFloat(x), y: 0, width: 1.5, height: size.height)), with: .color(Color(red: c.0, green: c.1, blue: c.2)))
            }
        }
    }
}

// MARK: - Spot channels

enum SpotEditState { static var editing: UUID? }

struct SpotChannelDialog: View {
    let editID: UUID?
    @State private var name: String
    @State private var ink: RGBA
    @State private var solidity: Double

    init() {
        editID = SpotEditState.editing
        let d = AppActions.doc
        if let id = editID, let info = d?.state.spotInfo(id) {
            _name = State(initialValue: d?.state.alphaChannels.first { $0.id == id }?.name ?? "Spot")
            _ink = State(initialValue: info.ink)
            _solidity = State(initialValue: info.solidity * 100)
        } else {
            let n = (d?.state.imaging?.spots.count ?? 0) + 1
            _name = State(initialValue: "Spot Color \(n)")
            _ink = State(initialValue: AppModel.shared.foreground)
            _solidity = State(initialValue: 0)
        }
    }

    var body: some View {
        ImagingDialogFrame(title: editID == nil ? "New Spot Channel" : "Spot Channel Options", width: 360, onOK: {
            AppModel.shared.dialog = nil
            SpotEditState.editing = nil
            guard let d = AppActions.doc else { return }
            if let id = editID, var info = d.state.spotInfo(id) {
                info.ink = ink; info.solidity = solidity / 100
                ColorModes.updateSpot(d, info, name: name)
            } else {
                ColorModes.addSpotChannel(d, name: name, ink: ink, solidity: solidity / 100)
            }
        }, onCancel: { SpotEditState.editing = nil }) {
            HStack { Text("Name").foregroundStyle(Theme.textDim).frame(width: 60, alignment: .leading); TextField("", text: $name).textFieldStyle(.plain).padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)) }
            HStack {
                Text("Color").foregroundStyle(Theme.textDim).frame(width: 60, alignment: .leading)
                ColorWell(color: $ink, size: 20)
                Spacer()
            }
            ValueSlider(label: "Solidity", value: $solidity, range: 0...100, unit: "%", labelWidth: 60)
            if editID == nil, AppActions.doc?.state.selection != nil {
                Text("The current selection is filled with the ink.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

/// Spot channel rows for the Channels panel.
struct ImagingChannelRows: View {
    let doc: Document

    static func compositeName(_ d: Document) -> String? {
        switch d.state.colorMode {
        case .bitmap: return "Bitmap"
        case .indexed: return "Index"
        case .duotone: return d.state.imaging?.duotone?.type.name ?? "Duotone"
        default: return nil
        }
    }

    var body: some View {
        ForEach(doc.state.spotChannels, id: \.0.id) { ch, info in
            HStack(spacing: 8) {
                Button {
                    var i = info; i.visible.toggle(); ColorModes.updateSpot(doc, i, commit: false); doc.setNeedsRender()
                } label: {
                    Image(systemName: info.visible ? "eye" : "eye.slash").font(.system(size: 10)).foregroundStyle(info.visible ? Theme.text : Theme.textFaint).frame(width: 18)
                }.buttonStyle(.plain)
                ZStack {
                    Color.white
                    if let img = SpotThumbs.image(ch, info: info, doc: doc) { Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit) }
                }.frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 2))
                Text(tr(ch.name)).font(Theme.font)
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: info.ink.nsColor)).frame(width: 10, height: 10)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(doc.viewChannel == .alpha(ch.id) ? Theme.selection : Color.clear)
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { SpotEditState.editing = ch.id; DialogRegistry.show("imaging.spot") })
            .simultaneousGesture(TapGesture().onEnded { doc.viewChannel = .alpha(ch.id); doc.setNeedsRender() })
            .contextMenu {
                Button("Spot Channel Options…") { SpotEditState.editing = ch.id; DialogRegistry.show("imaging.spot") }
                Button("Merge Spot Channel") { ColorModes.mergeSpot(doc, ch.id) }
                Button("Load as Selection") { AppActions.loadSelection(ch.id) }
                Button("Delete Channel") { ColorModes.deleteSpot(doc, ch.id) }
            }
        }
    }
}


/// Small ink-on-paper thumbnails of spot channels (cached per buffer version / ink).
enum SpotThumbs {
    private static var cache: [UUID: (Int, ObjectIdentifier, RGBA, Double, CGImage)] = [:]
    static func image(_ ch: AlphaChannel, info: SpotInfo, doc: Document) -> CGImage? {
        let b = ch.buffer
        if let c = cache[ch.id], c.0 == b.version, c.1 == ObjectIdentifier(b), c.2 == info.ink, c.3 == info.solidity { return c.4 }
        let side: CGFloat = 60
        let s = side / CGFloat(max(b.width, b.height))
        let r = CGRect(x: 0, y: 0, width: max(1, CGFloat(b.width) * s), height: max(1, CGFloat(b.height) * s)).integral
        let cov = b.ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        let img = ImagingDisplay.overlay(CIImage.color(.white, r), coverage: cov, info: info, rect: r)
        guard let cg = RenderEngine.cgImage(img, rect: r) else { return nil }
        cache[ch.id] = (b.version, ObjectIdentifier(b), info.ink, info.solidity, cg)
        return cg
    }
}
