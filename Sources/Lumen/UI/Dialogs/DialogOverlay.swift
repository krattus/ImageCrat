import SwiftUI
import ImageCratCore

struct DialogOverlay: View {
    static let accessibilityID = "lumen.dialog"
    @Bindable var app = AppModel.shared

    var body: some View {
        if let dlg = app.dialog {
            ZStack {
                Color.black.opacity(dimsCanvas(dlg) ? 0.35 : 0.001)
                    .ignoresSafeArea()
                    .onTapGesture {}
                    // let adjustment eyedroppers and the Blur Gallery's on-canvas pins reach the canvas
                    .allowsHitTesting(!CanvasSampler.shared.isArmed && dlg != .blurGallery)
                DraggableCard {
                    dialogView(dlg)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(DialogOverlay.accessibilityID)   // lets VoiceOver / UI automation find the dialog card
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dimsCanvas(dlg) ? .center : .topTrailing)
                .padding(.top, dimsCanvas(dlg) ? 0 : 60)
                .padding(.trailing, dimsCanvas(dlg) ? 0 : 320)
            }
            .id(dlg.id)
        }
    }

    func dimsCanvas(_ d: ActiveDialog) -> Bool {
        switch d {
        case .adjustment, .layerStyle, .colorRange, .selectAndMask, .focusArea, .globalLight, .blurGallery, .warpText: return false
        case .filter(let k, _, _): return k == .filterGallery
        case .custom(let id): return !DialogRegistry.nonDimming.contains(id)
        case .modifySelection(let k): return k != .feather      // the feather preview is shown on the canvas
        default: return true
        }
    }

    @ViewBuilder func dialogView(_ d: ActiveDialog) -> some View {
        switch d {
        case .newDocument: NewDocumentDialog()
        case .imageSize: ImageSizeProDialog()
        case .canvasSize: CanvasSizeDialog()
        case .filter(let k, let smart, let editing):
            if k == .filterGallery { FilterGalleryDialog(smartLayer: smart, editingFilter: editing) }
            else if k == .recipe { RecipeFilterDialog(smartLayer: smart, editingFilter: editing) }
            else if k == .liquify { LiquifyDialog(smartLayer: smart, editingFilter: editing) }
            else { FilterDialog(kind: k, smartLayer: smart, editingFilter: editing) }
        case .blurGallery:
            if let st = AppActions.blurGallery { BlurGalleryDialog(st: st) }
        case .adjustment(let k): AdjustmentDialog(kind: k)
        case .layerStyle(let id): LayerStyleDialog(layerID: id)
        case .export: ExportDialog()
        case .fill: FillDialog()
        case .stroke: StrokeDialog()
        case .modifySelection(let k): ModifySelectionDialog(kind: k)
        case .colorRange: ColorRangeProDialog()
        case .gradientEditor: GradientEditorDialog()
        case .about: AboutDialog()
        case .shortcuts: ShortcutsDialog()
        case .liquify: LiquifyDialog()
        case .selectAndMask: SelectAndMaskDialog()
        case .focusArea: FocusAreaDialog()
        case .globalLight: GlobalLightDialog()
        case .batch: BatchDialog()
        case .preferences: PreferencesDialog()
        case .colorProfile(let convert): ColorProfileDialog(convert: convert)
        case .proofSetup: ProofSetupDialog()
        case .warpText: WarpTextDialog()
        case .custom(let id): DialogRegistry.builders[id]?() ?? AnyView(EmptyView())
        }
    }
}

struct DraggableCard<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(white: 0.4)).frame(width: 36, height: 4).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { v in
                    if dragStart == nil { dragStart = offset }
                    offset = CGSize(width: dragStart!.width + v.translation.width, height: dragStart!.height + v.translation.height)
                }.onEnded { _ in dragStart = nil })
            content
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelBG))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .background(DialogCardMarker())
        .fixedSize()
        .offset(offset)
        .font(Theme.font)
        .foregroundStyle(Theme.text)
    }
}

/// An empty AppKit view behind the dialog card: tells `DialogFocus` which window holds the dialog and which of its views
/// are drawn above the card (the dialog's own controls) rather than under it (the panels).
struct DialogCardMarker: NSViewRepresentable {
    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { DialogFocus.marker = self } else if DialogFocus.marker === self { DialogFocus.marker = nil }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ v: MarkerView, context: Context) {}
}

struct DialogFrame<Content: View>: View {
    let title: String
    var width: CGFloat = 380
    var okTitle = "OK"
    var onOK: () -> Void
    var onCancel: (() -> Void)? = nil
    var extraButtons: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
            HStack {
                extraButtons
                Spacer()
                Button("Cancel") { onCancel?(); AppModel.shared.dialog = nil }
                    .buttonStyle(PanelButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(okTitle) { FieldEdits.commit(); onOK(); AppModel.shared.dialog = nil }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(width: width)
    }
}

// MARK: - New document

struct DocPreset: Identifiable { let id = UUID(); let name: String; let w: Int; let h: Int; let res: Double }

struct NewDocumentDialog: View {
    @State private var name = "Untitled-1"
    @State private var width: Double = 1920
    @State private var height: Double = 1080
    @State private var res: Double = 72
    @State private var bg = 0
    @State private var artboards = false

    static let presets: [DocPreset] = [
        DocPreset(name: "Default (1920 × 1080)", w: 1920, h: 1080, res: 72),
        DocPreset(name: "HD 1280 × 720", w: 1280, h: 720, res: 72),
        DocPreset(name: "4K UHD", w: 3840, h: 2160, res: 72),
        DocPreset(name: "Square 1080", w: 1080, h: 1080, res: 72),
        DocPreset(name: "Instagram Story", w: 1080, h: 1920, res: 72),
        DocPreset(name: "Letter (300 ppi)", w: 2550, h: 3300, res: 300),
        DocPreset(name: "A4 (300 ppi)", w: 2480, h: 3508, res: 300),
        DocPreset(name: "Web 1366 × 768", w: 1366, h: 768, res: 72),
        DocPreset(name: "iPhone 17 Pro", w: 1206, h: 2622, res: 460),
        DocPreset(name: "App Icon 1024", w: 1024, h: 1024, res: 72),
    ]

    var body: some View {
        DialogFrame(title: "New Document", width: 520, okTitle: "Create", onOK: create) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Caption("Presets")
                    ForEach(Self.presets) { p in
                        Button { width = Double(p.w); height = Double(p.h); res = p.res } label: {
                            HStack {
                                Image(systemName: p.w >= p.h ? "rectangle" : "rectangle.portrait").foregroundStyle(Theme.textDim)
                                Text(p.name)
                                Spacer()
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Int(width) == p.w && Int(height) == p.h ? Theme.selection : .clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 200)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    HStack {
                        NumberField(label: "Width", value: $width, width: 70)
                        Text("px").foregroundStyle(Theme.textFaint)
                    }
                    HStack {
                        NumberField(label: "Height", value: $height, width: 70)
                        Text("px").foregroundStyle(Theme.textFaint)
                        Button { swap(&width, &height) } label: { Image(systemName: "arrow.triangle.2.circlepath") }.buttonStyle(.plain).help("Swap orientation")
                    }
                    HStack {
                        NumberField(label: "Resolution", value: $res, width: 50)
                        Text("ppi").foregroundStyle(Theme.textFaint)
                    }
                    Picker("Background", selection: $bg) {
                        Text("White").tag(0); Text("Black").tag(1); Text("Background Color").tag(2); Text("Transparent").tag(3)
                    }
                    Toggle2(label: "Artboards", on: $artboards)
                        .help("Start with an artboard of this size (its background is the colour above) instead of a Background layer")
                    Text("\(Int(width)) × \(Int(height)) px · \(String(format: "%.1f", width * height * 4 / 1_048_576)) MB").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    func create() {
        let w = Int(clamp(width, 1, 30000)), h = Int(clamp(height, 1, 30000))
        let colors: [RGBA?] = [.white, .black, AppModel.shared.background, nil]
        if artboards {
            AppModel.shared.add(ArtboardActions.newDocument(width: w, height: h, resolution: res, background: colors[bg], name: name))
        } else {
            AppActions.newDocument(width: w, height: h, resolution: res, background: colors[bg], name: name)
        }
    }
}

// MARK: - Image size

struct ImageSizeDialog: View {
    @State private var width: Double = 0
    @State private var height: Double = 0
    @State private var res: Double = 72
    @State private var constrain = true
    @State private var percent = false
    @State private var scaleStyles = true
    @State private var ratio: Double = 1
    @State private var ow: Double = 1
    @State private var oh: Double = 1

    var body: some View {
        DialogFrame(title: "Image Size", width: 340, onOK: {
            let w = percent ? ow * width / 100 : width, h = percent ? oh * height / 100 : height
            AppActions.imageSize(width: Int(w.rounded()), height: Int(h.rounded()), resolution: res, scaleStyles: scaleStyles)
        }) {
            Picker("", selection: $percent) { Text("Pixels").tag(false); Text("Percent").tag(true) }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: percent) { _, p in
                    if p { width = width / ow * 100; height = height / oh * 100 } else { width = (width / 100 * ow).rounded(); height = (height / 100 * oh).rounded() }
                }
            HStack {
                NumberField(label: "Width", value: Binding(get: { width }, set: { v in width = v; if constrain { height = percent ? v : (v / ratio).rounded() } }), width: 70)
                Text(percent ? "%" : "px").foregroundStyle(Theme.textFaint)
            }
            HStack {
                NumberField(label: "Height", value: Binding(get: { height }, set: { v in height = v; if constrain { width = percent ? v : (v * ratio).rounded() } }), width: 70)
                Text(percent ? "%" : "px").foregroundStyle(Theme.textFaint)
            }
            Toggle2(label: "Constrain Proportions", on: $constrain)
            HStack { NumberField(label: "Resolution", value: $res, width: 50); Text("ppi").foregroundStyle(Theme.textFaint) }
            Toggle2(label: "Scale Styles", on: $scaleStyles)
            Text("Resampling: Bicubic / Lanczos (automatic)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .onAppear {
            guard let d = AppActions.doc else { return }
            ow = Double(d.state.width); oh = Double(d.state.height)
            width = ow; height = oh; res = d.state.resolution; ratio = ow / oh
        }
    }
}

// MARK: - Canvas size

struct CanvasSizeDialog: View {
    @State private var width: Double = 0
    @State private var height: Double = 0
    @State private var relative = false
    @State private var ax = 1
    @State private var ay = 1
    @State private var ext = 0

    var body: some View {
        DialogFrame(title: "Canvas Size", width: 340, onOK: apply) {
            if let d = AppActions.doc { Text("Current: \(d.state.width) × \(d.state.height) px").foregroundStyle(Theme.textDim) }
            HStack { NumberField(label: "Width", value: $width, width: 70); Text("px").foregroundStyle(Theme.textFaint) }
            HStack { NumberField(label: "Height", value: $height, width: 70); Text("px").foregroundStyle(Theme.textFaint) }
            Toggle2(label: "Relative", on: $relative)
                .onChange(of: relative) { _, r in
                    guard let d = AppActions.doc else { return }
                    if r { width -= Double(d.state.width); height -= Double(d.state.height) } else { width += Double(d.state.width); height += Double(d.state.height) }
                }
            HStack(alignment: .top) {
                Text("Anchor").foregroundStyle(Theme.textDim)
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(0..<3) { y in
                        GridRow {
                            ForEach(0..<3) { x in
                                Button { ax = x; ay = y } label: {
                                    Image(systemName: ax == x && ay == y ? "circle.fill" : "circle")
                                        .font(.system(size: 9)).frame(width: 24, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            Picker("Canvas extension color", selection: $ext) {
                Text("Transparent").tag(0); Text("Background").tag(1); Text("White").tag(2); Text("Black").tag(3)
            }
        }
        .onAppear {
            guard let d = AppActions.doc else { return }
            width = Double(d.state.width); height = Double(d.state.height)
        }
    }

    func apply() {
        guard let d = AppActions.doc else { return }
        let w = relative ? Double(d.state.width) + width : width
        let h = relative ? Double(d.state.height) + height : height
        let colors: [RGBA?] = [nil, AppModel.shared.background, .white, .black]
        AppActions.canvasSize(width: Int(w), height: Int(h), anchorX: ax, anchorY: ay, extension: colors[ext])
    }
}

// MARK: - Filter dialog

struct FilterDialog: View {
    let kind: FilterKind
    let smartLayer: UUID?
    let editingFilter: UUID?
    @State private var f: FilterInstance
    @State private var preview = true
    /// What the Center option's Object / Selection / Canvas mean for this dialog (filters about a centre point).
    private let centerContext: FilterCenterContext?
    @State private var centerThumb: CGImage?

    /// `seed`: settings to start from instead of the defaults (tests, scripted dialogs).
    init(kind: FilterKind, smartLayer: UUID?, editingFilter: UUID?, seed: FilterInstance? = nil) {
        self.kind = kind
        self.smartLayer = smartLayer
        self.editingFilter = editingFilter
        var inst = FilterInstance(kind: kind, colors: [AppModel.shared.foreground, AppModel.shared.background])
        if kind == .displace { inst.payload = AppActions.pendingFilterPayload }
        let doc = AppActions.doc
        centerContext = kind.usesCenter ? doc.map { FilterCenterResolver.context($0) } : nil
        if let eid = editingFilter, let sl = smartLayer, let so = doc?.state.layer(sl)?.smart, let ex = so.filters.first(where: { $0.id == eid }) {
            inst = ex
            inst.adoptLegacyCenter()   // (a filter from before the Center option shows as Canvas / Custom and renders the same)
        } else {
            // the centre: the object, the selection while there is one (a selected element twirls / spins about its own
            // middle), the canvas or a custom point — remembered per filter; a new smart filter is masked by the selection
            if let ctx = centerContext { FilterCenterMemory.start(&inst, ctx) }
            if let seed, seed.kind == kind { inst = seed }
            if smartLayer != nil { inst = AppActions.withSelectionMask(inst, doc) }
        }
        _f = State(initialValue: inst)
    }

    var body: some View {
        DialogFrame(title: kind.displayName + (smartLayer != nil ? " (Smart Filter)" : AppActions.filterTargetSuffix(AppActions.doc)), width: 360, onOK: ok, onCancel: cancel) {
            ForEach(kind.params.filter { !(kind.usesCenter && FilterCenterKey.all.contains($0.key)) }) { p in paramControl(p) }
            if let ctx = centerContext {
                Divider()
                FilterCenterSection(f: $f, ctx: ctx, thumbnail: centerThumb)
            }
            if smartLayer != nil {
                Divider()
                HStack {
                    Text("Mode").foregroundStyle(Theme.textDim)
                    BlendModePicker(mode: $f.blendMode, width: 120)
                }
                ValueSlider(label: "Opacity", value: Binding(get: { f.opacity * 100 }, set: { f.opacity = $0 / 100 }), range: 0...100, unit: "%")
            }
            Toggle2(label: "Preview", on: $preview)
        }
        .onChange(of: f) { _, _ in updatePreview() }
        .onChange(of: preview) { _, _ in updatePreview() }
        .onAppear {
            updatePreview()
            if centerContext != nil, let d = AppActions.doc { centerThumb = FilterCenterSection.thumbnail(smartLayer != nil ? d.committedState : d.state) }
        }
    }

    @ViewBuilder func paramControl(_ p: FilterParam) -> some View {
        let b = Binding(get: { f.values[p.key] ?? p.defaultValue }, set: { f.values[p.key] = $0 })
        switch p.kind {
        case .slider(let r):
            let fmt = r.upperBound - r.lowerBound <= 2 ? "%.2f" : (r.upperBound - r.lowerBound <= 20 ? "%.1f" : "%.0f")
            ValueSlider(label: p.label, value: b, range: r, unit: p.unit, format: fmt, labelWidth: 96)
        case .angle:
            HStack {
                Text(p.label).foregroundStyle(Theme.textDim).frame(width: 96, alignment: .leading)
                AngleDial(angle: b)
                NumberField(label: "", value: b, width: 44)
                Text("°").foregroundStyle(Theme.textFaint)
            }
        case .toggle:
            Toggle2(label: p.label, on: Binding(get: { b.wrappedValue > 0.5 }, set: { b.wrappedValue = $0 ? 1 : 0 }))
        case .choice(let opts):
            Picker(p.label, selection: Binding(get: { Int(b.wrappedValue) }, set: { b.wrappedValue = Double($0) })) {
                ForEach(Array(opts.enumerated()), id: \.offset) { i, o in Text(o).tag(i) }
            }
        case .percentPoint:
            ValueSlider(label: p.label, value: Binding(get: { b.wrappedValue * 100 }, set: { b.wrappedValue = $0 / 100 }), range: 0...100, unit: "%", labelWidth: 96)
        }
    }

    func updatePreview() {
        guard let d = AppActions.doc else { return }
        if let sl = smartLayer {
            // live-edit the smart filter stack
            var filters = d.committedState.layer(sl)?.smart?.filters ?? []
            if preview {
                if let eid = editingFilter, let i = filters.firstIndex(where: { $0.id == eid }) { filters[i] = f } else { filters.append(f) }
            }
            d.updateLayer(sl) { $0.smart?.filters = filters }
            return
        }
        if preview {
            let inst = f
            let canvas = CanvasSpace(width: d.state.width, height: d.state.height).ciCanvas
            AppActions.setPreview { inst.apply($0, canvas: canvas) }
        } else {
            AppActions.setPreview(nil)
        }
    }

    func ok() {
        guard let d = AppActions.doc else { return }
        CanvasSampler.shared.disarm(FilterCenterSection.samplerToken); FilterCenterSection.endCanvasDrag()
        FilterCenterMemory.save(f)
        if let sl = smartLayer {
            var filters = d.committedState.layer(sl)?.smart?.filters ?? []
            if let eid = editingFilter, let i = filters.firstIndex(where: { $0.id == eid }) { filters[i] = f } else { filters.append(f) }
            d.updateLayer(sl) { $0.smart?.filters = filters }
            d.commit(kind.displayName)
            AppActions.lastFilter = f
            return
        }
        AppActions.setPreview(nil)
        AppActions.applyFilter(f)
    }

    func cancel() {
        CanvasSampler.shared.disarm(FilterCenterSection.samplerToken); FilterCenterSection.endCanvasDrag()
        guard let d = AppActions.doc else { return }
        if smartLayer != nil { d.revertUncommitted() } else { AppActions.setPreview(nil) }
    }
}

// MARK: - Adjustment dialog (destructive)

struct AdjustmentDialog: View {
    let kind: AdjustmentKind
    @State private var s: AdjustmentSettings
    @State private var preview = true

    init(kind: AdjustmentKind) {
        self.kind = kind
        _s = State(initialValue: AdjustmentSettings(kind: kind))
    }

    var body: some View {
        DialogFrame(title: kind.displayName, width: kind == .curves || kind == .levels ? 340 : 360, onOK: {
            AppActions.setPreview(nil)
            AppActions.applyAdjustment(s)
        }, onCancel: { AppActions.setPreview(nil) }) {
            AdjustmentControls(s: $s, doc: AppActions.doc, onCommit: {})
            Toggle2(label: "Preview", on: $preview)
        }
        .onChange(of: s) { _, _ in updatePreview() }
        .onChange(of: preview) { _, _ in updatePreview() }
        .onAppear { updatePreview() }
    }

    func updatePreview() {
        if preview {
            let st = s
            AppActions.setPreview { AdjustmentEngine.apply(st, to: $0) }
        } else {
            AppActions.setPreview(nil)
        }
    }
}

// MARK: - Export

struct ExportDialog: View {
    @State private var format: ExportFormat = .png
    @State private var quality: Double = 90
    @State private var scale: Double = 100
    @State private var transparent = true
    @State private var estimate: String = "—"
    @State private var credentials = ContentCredentials.attachOnExport

    var body: some View {
        DialogFrame(title: "Export As", width: 360, okTitle: "Export…", onOK: export) {
            Picker("Format", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
            if format.supportsQuality {
                ValueSlider(label: "Quality", value: $quality, range: 1...100, unit: "%")
            }
            ValueSlider(label: "Scale", value: $scale, range: 5...400, unit: "%")
            if format.supportsAlpha && format != .psd { Toggle2(label: "Transparency", on: $transparent) }
            if let d = AppActions.doc {
                Text("Output: \(Int(Double(d.state.width) * scale / 100)) × \(Int(Double(d.state.height) * scale / 100)) px").foregroundStyle(Theme.textDim)
            }
            HStack {
                Text("Estimated size: \(estimate)").foregroundStyle(Theme.textDim)
                Spacer()
                Button("Estimate") { estimateSize() }.buttonStyle(PanelButtonStyle())
            }
            if format == .png { WebExportExportAsRow() }
            if format == .psd { Text("Layers, groups, masks, blend modes, opacity and layer styles (editable in Photoshop) are preserved.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            if [.png, .jpeg, .tiff, .heic, .gif].contains(format) { Toggle2(label: "Attach Content Credentials", on: $credentials).onChange(of: credentials) { _, v in ContentCredentials.attachOnExport = v } }
        }
    }

    func estimateSize() {
        guard let d = AppActions.doc else { return }
        if let b = DocumentIO.estimateSize(d.state, format: format, quality: quality / 100, scale: scale / 100) {
            estimate = ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
        }
    }

    func export() {
        guard let d = AppActions.doc else { return }
        let st = d.state
        let fmt = format, q = quality / 100, sc = scale / 100
        let bg: RGBA? = transparent ? nil : .white
        let p = NSSavePanel()
        p.allowedContentTypes = [fmt.utType]
        p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + "." + fmt.ext
        UIBlock.begin(p) { r in
            guard r == .OK, let url = p.url else { return }
            do { try DocumentIO.export(st, to: url, format: fmt, quality: q, scale: sc, background: bg) } catch { AppActions.alert("Export failed.", error.localizedDescription); return }
            if credentials && fmt != .psd && fmt != .bmp { do { try ContentCredentials.signExport(url, document: d) } catch { AppActions.alert("Content Credentials could not be attached.", error.localizedDescription) } }
        }
    }
}

// MARK: - Fill / Stroke / Modify / Color range

struct FillDialog: View {
    @State private var contents: FillContents = .foreground
    @State private var color: RGBA = AppModel.shared.foreground
    @State private var patternID = AppModel.shared.bucket.patternID
    @State private var opacity: Double = 100
    @State private var mode: BlendMode = .normal
    @State private var preserve = false

    var body: some View {
        DialogFrame(title: "Fill", width: 340, onOK: {
            AppActions.fill(contents, color: color, patternID: patternID, opacity: opacity / 100, mode: mode, preserveTransparency: preserve)
        }) {
            Picker("Contents", selection: $contents) { ForEach(FillContents.allCases) { Text($0.rawValue).tag($0) } }
            if contents == .color { HStack { Text("Color").foregroundStyle(Theme.textDim); ColorWell(color: $color) } }
            if contents == .pattern { HStack { Text("Pattern").foregroundStyle(Theme.textDim); PatternPicker(patternID: $patternID) } }
            HStack { Text("Mode").foregroundStyle(Theme.textDim); BlendModePicker(mode: $mode) }
            ValueSlider(label: "Opacity", value: $opacity, range: 0...100, unit: "%")
            Toggle2(label: "Preserve Transparency", on: $preserve)
        }
    }
}

struct StrokeDialog: View {
    @State private var width: Double = 3
    @State private var color: RGBA = AppModel.shared.foreground
    @State private var location: StrokeLocation = .center
    @State private var opacity: Double = 100
    @State private var mode: BlendMode = .normal

    var body: some View {
        DialogFrame(title: "Stroke", width: 340, onOK: {
            AppActions.strokeSelection(width: width, color: color, location: location, opacity: opacity / 100, mode: mode)
        }) {
            ValueSlider(label: "Width", value: $width, range: 1...250, unit: "px")
            HStack { Text("Color").foregroundStyle(Theme.textDim); ColorWell(color: $color) }
            Picker("Location", selection: $location) { ForEach(StrokeLocation.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            HStack { Text("Mode").foregroundStyle(Theme.textDim); BlendModePicker(mode: $mode) }
            ValueSlider(label: "Opacity", value: $opacity, range: 0...100, unit: "%")
        }
    }
}

struct ModifySelectionDialog: View {
    let kind: ModifySelectionKind
    @State private var amount: Double = 5
    @State private var direction = AppModel.shared.featherDirection
    @State private var base: PixelBuffer? = AppActions.doc?.state.selection
    @State private var preview = true

    var body: some View {
        DialogFrame(title: "\(kind.rawValue) Selection", width: kind == .feather ? 340 : 300, onOK: {
            restore()
            if kind == .feather { AppModel.shared.featherDirection = direction }
            AppActions.modifySelection(kind, amount: amount, direction: direction)
        }, onCancel: { restore() }) {
            ValueSlider(label: kind == .feather ? "Feather Radius" : kind == .border ? "Width" : kind == .smooth ? "Sample Radius" : "\(kind.rawValue) By",
                        value: $amount, range: 0...250, unit: "px", format: "%.1f", labelWidth: 96)
            if kind == .feather {
                FeatherDirectionPicker(direction: $direction, labelWidth: 96)
                Text(direction.help).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Toggle2(label: "Preview (quick mask)", on: $preview)
            }
        }
        .onChange(of: amount) { _, _ in updatePreview() }
        .onChange(of: direction) { _, _ in updatePreview() }
        .onChange(of: preview) { _, _ in updatePreview() }
        .onAppear { updatePreview() }
    }

    /// Shows the feathered result as a red overlay while the dialog is open (selection edges alone can't show softness).
    private func updatePreview() {
        guard kind == .feather, let d = AppActions.doc, let b = base else { return }
        if preview {
            let m = SelectionOps.feather(b, radius: amount, direction: direction)
            let space = CanvasSpace(width: d.state.width, height: d.state.height)
            let red = CIImage.color(RGBA(r: 1, g: 0, b: 0, a: 0.5), space.ciCanvas).masked(byGray: m.ciImage.inverted())
            d.displayOverride = { red.composited(over: $0) }
        } else {
            d.displayOverride = nil
        }
        d.setNeedsRender()
    }

    private func restore() {
        guard kind == .feather, let d = AppActions.doc else { return }
        d.displayOverride = nil
        d.setNeedsRender()
    }
}

/// Segmented Centered / Inside / Outside chooser used wherever a feather radius is set.
struct FeatherDirectionPicker: View {
    @Binding var direction: FeatherDirection
    var labelWidth: CGFloat = 60
    var body: some View {
        WrappingHStack(spacing: 6) {   // (in a narrow panel the choices go under the label, as a menu if need be)
            Text("Direction").foregroundStyle(Theme.textDim).frame(width: labelWidth, alignment: .leading)
            Picker("", selection: $direction) {
                ForEach(FeatherDirection.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().segmentedOrMenu()
        }
    }
}

/// Compact options-bar menu for the feather direction.
struct FeatherDirectionMenu: View {
    @Binding var direction: FeatherDirection
    var body: some View {
        Menu {
            ForEach(FeatherDirection.allCases) { d in
                Button((direction == d ? "✓ " : "    ") + d.rawValue + " — " + d.help) { direction = d }
            }
        } label: {
            Text(direction.rawValue)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Feather direction: " + direction.help)
    }
}

struct ColorRangeDialog: View {
    @State private var color: RGBA = AppModel.shared.foreground
    @State private var fuzz: Double = 40
    @State private var invert = false
    var body: some View {
        DialogFrame(title: "Color Range", width: 320, onOK: {
            AppActions.doc?.revertUncommitted()
            AppActions.colorRange(color: color, fuzziness: fuzz, invert: invert)
        }, onCancel: { AppActions.doc?.revertUncommitted() }) {
            HStack {
                Text("Sampled Color").foregroundStyle(Theme.textDim)
                ColorWell(color: $color)
                Button { NSColorSampler().show { c in if let c { color = RGBA(nsColor: c) } } } label: { Image(systemName: "eyedropper") }.buttonStyle(.plain)
            }
            ValueSlider(label: "Fuzziness", value: $fuzz, range: 0...200)
            Toggle2(label: "Invert", on: $invert)
            Button("Preview") {
                guard let d = AppActions.doc, let src = AppActions.sampleSource(allLayers: true) else { return }
                var m = SelectionOps.colorRange(src: src, color: color, fuzziness: fuzz)
                if invert { m = SelectionOps.invert(m) }
                d.state.selection = m
                d.setNeedsOverlay()
            }.buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - Gradient editor

struct GradientStopsEditor: View {
    @Binding var gradient: ColorGradient
    var onCommit: (() -> Void)? = nil
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    GradientSwatch(gradient: gradient).frame(height: 22)
                    ForEach(gradient.stops) { st in
                        VStack(spacing: 0) {
                            Path { p in p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 12, y: 6)); p.addLine(to: CGPoint(x: 0, y: 6)); p.closeSubpath() }
                                .fill(selected == st.id ? Theme.accent : Color(white: 0.7)).frame(width: 12, height: 6)
                            Rectangle().fill(Color(nsColor: st.color.nsColor)).frame(width: 12, height: 12)
                                .overlay(Rectangle().stroke(selected == st.id ? Theme.accent : Color(white: 0.7), lineWidth: 1))
                        }
                        .offset(x: st.location * g.size.width - 6, y: 24)
                        .gesture(DragGesture().onChanged { v in
                            selected = st.id
                            if let i = gradient.stops.firstIndex(where: { $0.id == st.id }) {
                                let x = st.location * g.size.width + v.translation.width
                                if v.translation.height > 40 && gradient.stops.count > 2 { return }
                                gradient.stops[i].location = clamp(Double(x / g.size.width), 0, 1)
                            }
                        }.onEnded { v in
                            if v.translation.height > 40 && gradient.stops.count > 2 { gradient.stops.removeAll { $0.id == st.id } }
                            onCommit?()
                        })
                        .onTapGesture { selected = st.id }
                    }
                }
            }
            .frame(height: 44)
            HStack {
                Button {
                    let loc = 0.5
                    gradient.stops.append(GradientStop(location: loc, color: gradient.color(at: loc)))
                    onCommit?()
                } label: { Label("Add Stop", systemImage: "plus") }.buttonStyle(PanelButtonStyle())
                if let sid = selected, gradient.stops.contains(where: { $0.id == sid }) {
                    // looked up by id: the stop can be removed (trash button) while the colour popover / field still holds its binding
                    ColorWell(color: Binding(get: { gradient.stops.first { $0.id == sid }?.color ?? .black },
                                             set: { v in if let j = gradient.stops.firstIndex(where: { $0.id == sid }) { gradient.stops[j].color = v } }), size: 18, showAlpha: true, onCommit: onCommit)
                    NumberField(label: "", value: Binding(get: { (gradient.stops.first { $0.id == sid }?.location ?? 0) * 100 },
                                                          set: { v in if let j = gradient.stops.firstIndex(where: { $0.id == sid }) { gradient.stops[j].location = clamp(v / 100, 0, 1) } }), width: 36, onCommit: onCommit)
                    Text("%").foregroundStyle(Theme.textFaint)
                    if gradient.stops.count > 2 {
                        Button { gradient.stops.removeAll { $0.id == sid }; selected = nil; onCommit?() } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct GradientEditorDialog: View {
    @Bindable var app = AppModel.shared
    @State private var g: ColorGradient = AppModel.shared.gradientTool.gradient
    var body: some View {
        DialogFrame(title: "Gradient Editor", width: 360, onOK: {
            app.gradientTool.gradient = g
            app.gradientTool.useForegroundBackground = false
        }) {
            GradientPresetGrid(selected: $g)
            TextField("Name", text: $g.name).textFieldStyle(.roundedBorder)
            GradientStopsEditor(gradient: $g)
            Button("Save as New Preset") {
                var n = g; n.id = UUID()
                app.gradients.append(n)
            }.buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - About / shortcuts

struct AboutDialog: View {
    var body: some View {
        VStack(spacing: 10) {
            if AppInfo.isAppBundle, let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            } else {
                Image(systemName: "camera.aperture").font(.system(size: 48, weight: .thin))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.4, green: 0.7, blue: 1), Color(red: 0.7, green: 0.4, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Text(Brand.name).font(.system(size: 22, weight: .light))
            Text(AppInfo.versionLine).foregroundStyle(Theme.textDim).textSelection(.enabled)   // CFBundleShortVersionString (CFBundleVersion)
            Text("A layered image editor for macOS built on Core Image & Metal.").multilineTextAlignment(.center).foregroundStyle(Theme.textDim)
            Text("macOS \(AppInfo.macOS.replacingOccurrences(of: "Version ", with: "")) · \(AppInfo.chip)").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            HStack {
                Button("Copy Version") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(Brand.name) \(AppInfo.version) (\(AppInfo.build)), macOS \(AppInfo.macOS.replacingOccurrences(of: "Version ", with: "")), \(AppInfo.modelIdentifier)", forType: .string)
                }.buttonStyle(PanelButtonStyle())
                Button("Report a Bug…") {
                    AppModel.shared.dialog = nil
                    DispatchQueue.main.async { TesterKitModule.openBugReport() }   // after the About card is gone (not in the window snapshot)
                }.buttonStyle(PanelButtonStyle())
                Button("Close") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

struct ShortcutsDialog: View {
    let rows: [(String, String)] = [
        ("V", "Move"), ("M", "Marquee"), ("L", "Lasso"), ("W", "Magic Wand / Quick Selection"), ("C", "Crop"), ("I", "Eyedropper"),
        ("J", "Healing"), ("B", "Brush / Pencil"), ("S", "Clone Stamp"), ("Y", "History Brush"), ("E", "Eraser"), ("G", "Gradient / Bucket"),
        ("R", "Blur / Sharpen / Smudge"), ("O", "Dodge / Burn / Sponge"), ("P", "Pen"), ("T", "Type"), ("A", "Path Selection"), ("U", "Shapes"),
        ("H / Space", "Hand"), ("Z", "Zoom"), ("⇧ + key", "Cycle tools in group"), ("[ / ]", "Brush size"), ("{ / }", "Brush hardness"),
        ("0–9", "Tool opacity"), ("D / X", "Default / swap colors"), ("Q", "Quick mask"), ("Tab", "Toggle panels"),
        ("⌘T", "Free Transform"), ("⌘J", "Layer via Copy"), ("⌘G", "Group"), ("⌥⌘G", "Clipping Mask"), ("⌘E", "Merge Down"),
        ("⌘L / ⌘M / ⌘U", "Levels / Curves / Hue-Sat"), ("⌘D", "Deselect"), ("⇧⌘I", "Inverse"), ("⌥⌫", "Fill with foreground"),
        ("⌘+ / ⌘−", "Zoom in / out"), ("⌘0 / ⌘1", "Fit / 100% (also ⌥⌘0)"), ("⌘R", "Rulers"), ("⌘'", "Grid"),
        ("⇧⌘X", "Liquify"), ("⇧⌘A", "Camera Raw Filter"), ("⌃⌘F", "Repeat last filter"), ("Space-drag", "Pan"), ("⌥-scroll / pinch", "Zoom"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard Shortcuts").font(.system(size: 13, weight: .semibold))
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(rows, id: \.0) { r in
                        GridRow {
                            Text(r.0).font(Theme.mono).foregroundStyle(Theme.accent)
                            Text(r.1)
                        }
                    }
                }
            }.frame(height: 380)
            HStack { Spacer(); Button("Close") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 380)
    }
}


// MARK: - Focus Area / Global Light

struct FocusAreaDialog: View {
    @State private var range: Double = 50
    @State private var noise: Double = 10
    var body: some View {
        DialogFrame(title: "Focus Area", width: 320, onOK: {
            AppActions.doc?.revertUncommitted()
            if let m = AppActions.focusAreaMask(range: range, noise: noise) { AppActions.doc?.setSelection(m, commitName: "Focus Area") }
        }, onCancel: { AppActions.doc?.revertUncommitted() }) {
            ValueSlider(label: "In-Focus Range", value: $range, range: 0...100, labelWidth: 96)
            ValueSlider(label: "Image Noise", value: $noise, range: 0...100, labelWidth: 96)
            Button("Preview") {
                guard let d = AppActions.doc, let m = AppActions.focusAreaMask(range: range, noise: noise) else { return }
                d.state.selection = m
                d.setNeedsOverlay()
            }.buttonStyle(PanelButtonStyle())
        }
    }
}

struct GlobalLightDialog: View {
    @State private var angle: Double = AppActions.doc?.state.globalLight.angle ?? 120
    @State private var altitude: Double = AppActions.doc?.state.globalLight.altitude ?? 30
    var body: some View {
        DialogFrame(title: "Global Light", width: 300, onOK: {
            guard let d = AppActions.doc else { return }
            d.state.globalLight = GlobalLight(angle: angle, altitude: altitude)
            d.commit("Global Light")
        }, onCancel: { AppActions.doc?.revertUncommitted() }) {
            HStack {
                Text("Angle").foregroundStyle(Theme.textDim).frame(width: 60, alignment: .leading)
                AngleDial(angle: $angle)
                NumberField(label: "", value: $angle, width: 44)
                Text("°").foregroundStyle(Theme.textFaint)
            }
            ValueSlider(label: "Altitude", value: $altitude, range: 0...90, unit: "°", labelWidth: 60)
        }
        .onChange(of: angle) { _, v in AppActions.doc?.state.globalLight.angle = v }
        .onChange(of: altitude) { _, v in AppActions.doc?.state.globalLight.altitude = v }
    }
}
