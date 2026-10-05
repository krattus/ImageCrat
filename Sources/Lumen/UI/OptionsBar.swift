import SwiftUI
import ImageCratCore

struct OptionsBar: View {
    @Bindable var app = AppModel.shared

    var body: some View {
        HStack(spacing: 10) {
            ToolPresetPicker()
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .frame(width: 42, height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
                .help(app.tool.displayName + " — tool presets")
            Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
            toolOptions
            if SymmetryControls.supports(app.tool) { SymmetryMenu() }
            if SymmetryControls.supports(app.tool) { AssistMenu() }   // assisted drawing, stabiliser, test pad
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .font(Theme.font)
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder var toolOptions: some View {
        switch app.tool {
        case .move: MoveOptions()
        case .marqueeRect, .marqueeEllipse, .marqueeRow, .marqueeColumn, .lasso, .polygonLasso: SelectionOptions(showStyle: app.tool == .marqueeRect || app.tool == .marqueeEllipse)
        case .magneticLasso: MagneticLassoOptions()
        case .objectSelect: ObjectSelectOptionsBar()
        case .patch: PatchOptions()
        case .contentAwareMove: ContentAwareMoveOptions()
        case .removeTool: RemoveOptions()
        case .redEye:
            CompactSlider(label: "Pupil Size", value: $app.redEyePupil, range: 1...100, unit: "%")
            CompactSlider(label: "Darken Amount", value: $app.redEyeDarken, range: 1...100, unit: "%")
            Text("Click or drag over a red eye.").foregroundStyle(Theme.textFaint)
        case .colorReplacement: ColorReplacementOptions()
        case .mixerBrush: MixerOptions()
        case .rotateView:
            Text("Rotation: \(Int(((app.activeDocument?.viewRotation ?? 0) * 180 / .pi).rounded()))°").font(Theme.mono)
            Button("Reset View") { AppActions.canvas?.setRotation(0) }.buttonStyle(PanelButtonStyle())
            Text("Drag to rotate · ⇧ snaps to 15° · double-click or Esc resets").foregroundStyle(Theme.textFaint)
        case .magicWand: WandOptions()
        case .quickSelect: QuickSelectOptions()
        case .crop: CropOptions()
        case .eyedropper: EyedropperOptions()
        case .brush, .pencil, .eraser, .historyBrush, .cloneStamp, .healing, .spotHealing: BrushOptions()
        case .magicEraser:
            CompactSlider(label: "Tolerance", value: $app.magicEraserTolerance, range: 0...255)
        case .gradient: GradientOptions()
        case .paintBucket: BucketOptions()
        case .blur, .sharpen, .smudge, .dodge, .burn, .sponge: RetouchOptions()
        case .pen, .freeformPen:
            ToolModePicker(tool: app.tool)
            if app.penMode == .shape { ShapeFillStrokeControls() }
            Text("Click to add points, drag for curves, click the first point to close. ⌘-click to finish.").foregroundStyle(Theme.textDim)
        case .directSelect, .pathSelect: PathOptions()
        case .text, .verticalText: TextOptions()
        case .rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape: ShapeOptions()
        case .hand, .zoom: ViewOptions()
        default: ExtraToolOptions()
        }
    }
}

// MARK: - Shared bits

struct CompactSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    var scale: Double = 1   // displayed = value * scale
    var width: CGFloat = 90

    @State private var showSlider = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.textDim)
            Button { showSlider.toggle() } label: {
                HStack(spacing: 2) {
                    Text(String(format: "%.0f", value * scale) + unit).font(Theme.mono)
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSlider, arrowEdge: .bottom) {
                Slider(value: $value, in: range).frame(width: 180).padding(10)
            }
        }
    }
}

struct Toggle2: View {
    let label: String
    @Binding var on: Bool
    var body: some View {
        Toggle(label, isOn: $on).toggleStyle(.checkbox).font(Theme.font)
    }
}

struct ModePicker: View {
    @Binding var mode: ShapeMode
    var body: some View {
        Picker("", selection: $mode) {
            ForEach(ShapeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
        .labelsHidden()
    }
}

struct CombineModeButtons: View {
    @Binding var mode: SelectionCombine
    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "square", help: "New Selection", active: mode == .new) { mode = .new }
            IconButton(symbol: "plus.square", help: "Add to Selection (Shift)", active: mode == .add) { mode = .add }
            IconButton(symbol: "minus.square", help: "Subtract from Selection (Option)", active: mode == .subtract) { mode = .subtract }
            IconButton(symbol: "square.on.square.intersection.dashed", help: "Intersect with Selection", active: mode == .intersect) { mode = .intersect }
        }
    }
}

// MARK: - Tool option groups

struct MoveOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let _ = app.sessionTick
        if let i = (AppActions.canvas?.tool(for: .move) as? MoveTool)?.interactive {
            InteractiveSessionOptions(session: i)
        } else {
            standard
        }
    }

    @ViewBuilder var standard: some View {
        let session = (AppActions.canvas?.currentTool as? MoveTool)?.session
        Toggle2(label: "Auto-Select:", on: $app.moveAutoSelect)
            .help("Click a layer's pixels on the canvas to select it (⌘-click does the opposite of this setting)")
        Picker("", selection: $app.moveAutoSelectMode) { ForEach(AutoSelectMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            .labelsHidden().frame(width: 74).disabled(!app.moveAutoSelect)
            .help("Auto-select the layer under the cursor, or the top-level group that contains it")
        Toggle2(label: "Show Transform Controls", on: $app.moveShowTransform)
        Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
        HStack(spacing: 2) {
            IconButton(symbol: "align.horizontal.left", help: "Align Left Edges") { AppActions.align(.left) }
            IconButton(symbol: "align.horizontal.center", help: "Align Horizontal Centers") { AppActions.align(.hCenter) }
            IconButton(symbol: "align.horizontal.right", help: "Align Right Edges") { AppActions.align(.right) }
            IconButton(symbol: "align.vertical.top", help: "Align Top Edges") { AppActions.align(.top) }
            IconButton(symbol: "align.vertical.center", help: "Align Vertical Centers") { AppActions.align(.vCenter) }
            IconButton(symbol: "align.vertical.bottom", help: "Align Bottom Edges") { AppActions.align(.bottom) }
            IconButton(symbol: "distribute.horizontal.center", help: "Distribute Horizontally") { AppActions.distribute(horizontal: true) }
            IconButton(symbol: "distribute.vertical.center", help: "Distribute Vertically") { AppActions.distribute(horizontal: false) }
        }
        if session != nil || app.statusMessage.hasPrefix("X:") {
            Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
            Text(app.statusMessage).font(Theme.mono).foregroundStyle(Theme.textDim)
            Button { AppActions.canvas?.cancelCurrentTool() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel Transform (Esc)")
            Button { AppActions.canvas?.commitCurrentTool() } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }.buttonStyle(.plain).help("Commit Transform (Return)")
            Text("⌘ distort · ⌘⇧ skew · ⌘⌥⇧ perspective · ⇧ free scale").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

struct SelectionOptions: View {
    @Bindable var app = AppModel.shared
    var showStyle: Bool
    var body: some View {
        CombineModeButtons(mode: $app.selection.combine)
        CompactSlider(label: "Feather", value: $app.selection.feather, range: 0...250, unit: " px")
        FeatherDirectionMenu(direction: $app.featherDirection)
        Toggle2(label: "Anti-alias", on: $app.selection.antialias)
        if showStyle {
            Toggle2(label: "Fixed Ratio", on: $app.selection.fixedRatio)
            if app.selection.fixedRatio {
                NumberField(label: "W", value: $app.selection.ratioW, width: 36)
                NumberField(label: "H", value: $app.selection.ratioH, width: 36)
            }
        }
        Button("Select Subject") { AppActions.selectSubject() }.buttonStyle(PanelButtonStyle())
    }
}

struct WandOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CombineModeButtons(mode: $app.selection.combine)
        CompactSlider(label: "Tolerance", value: $app.selection.tolerance, range: 0...255)
        Toggle2(label: "Anti-alias", on: $app.selection.antialias)
        Toggle2(label: "Contiguous", on: $app.selection.contiguous)
        Toggle2(label: "Sample All Layers", on: $app.selection.sampleAllLayers)
        Button("Select Subject") { AppActions.selectSubject() }.buttonStyle(PanelButtonStyle())
    }
}

struct QuickSelectOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CompactSlider(label: "Size", value: $app.quickSelectSize, range: 2...300, unit: " px")
        Text("Paint over the area to select. Option-drag to subtract.").foregroundStyle(Theme.textDim)
        Button("Select Subject") { AppActions.selectSubject() }.buttonStyle(PanelButtonStyle())
    }
}

struct CropOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        Menu {
            Button("Ratio (Free)") { app.crop.ratioW = 0; app.crop.ratioH = 0 }
            Button("1 : 1 (Square)") { app.crop.ratioW = 1; app.crop.ratioH = 1 }
            Button("4 : 5 (8 : 10)") { app.crop.ratioW = 4; app.crop.ratioH = 5 }
            Button("5 : 7") { app.crop.ratioW = 5; app.crop.ratioH = 7 }
            Button("2 : 3 (4 : 6)") { app.crop.ratioW = 2; app.crop.ratioH = 3 }
            Button("3 : 2") { app.crop.ratioW = 3; app.crop.ratioH = 2 }
            Button("4 : 3") { app.crop.ratioW = 4; app.crop.ratioH = 3 }
            Button("16 : 9") { app.crop.ratioW = 16; app.crop.ratioH = 9 }
        } label: { Text(app.crop.ratioW > 0 ? "\(Int(app.crop.ratioW)) : \(Int(app.crop.ratioH))" : "Ratio") }
            .menuStyle(.borderlessButton).frame(width: 80)
        NumberField(label: "", value: $app.crop.ratioW, width: 36)
        Image(systemName: "arrow.left.arrow.right").font(.system(size: 9)).onTapGesture { swap(&app.crop.ratioW, &app.crop.ratioH) }
        NumberField(label: "", value: $app.crop.ratioH, width: 36)
        Toggle2(label: "Delete Cropped Pixels", on: $app.crop.deleteCropped)
        Toggle2(label: "Rule of Thirds", on: $app.crop.showThirds)
        CropStraightenControls()
        GenAICropExpandOption()
        Button { AppActions.canvas?.cancelCurrentTool() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel (Esc)")
        Button { AppActions.canvas?.commitCurrentTool() } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }.buttonStyle(.plain).help("Commit (Return)")
    }
}

struct EyedropperOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        Picker("Sample Size", selection: $app.eyedropperSample) {
            Text("Point Sample").tag(1)
            Text("3 by 3 Average").tag(3)
            Text("5 by 5 Average").tag(5)
            Text("11 by 11 Average").tag(11)
        }.frame(width: 220)
        Toggle2(label: "Sample All Layers", on: $app.eyedropperAllLayers)
    }
}

struct BrushOptions: View {
    @Bindable var app = AppModel.shared
    @State private var showBrushes = false

    var body: some View {
        let s = Binding(get: { app.activeBrushSettings }, set: { app.activeBrushSettings = $0 })
        Button { showBrushes.toggle() } label: {
            HStack(spacing: 4) {
                BrushTipPreview(settings: s.wrappedValue).frame(width: 22, height: 22)
                Text("\(Int(s.wrappedValue.size))").font(Theme.mono)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showBrushes, arrowEdge: .bottom) { BrushSettingsView(settings: s).frame(width: 300).padding(10) }

        if app.tool == .eraser {
            Picker("Mode", selection: $app.eraserMode) { ForEach(EraserMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 120)
        } else if app.tool != .historyBrush && app.tool != .healing && app.tool != .spotHealing {
            Text("Mode").foregroundStyle(Theme.textDim)
            BlendModePicker(mode: s.blendMode, width: 110)
        }
        CompactSlider(label: "Opacity", value: s.opacity, range: 0...1, unit: "%", scale: 100)
        CompactSlider(label: "Flow", value: s.flow, range: 0.01...1, unit: "%", scale: 100)
        CompactSlider(label: "Smoothing", value: s.smoothing, range: 0...0.95, unit: "%", scale: 100)
        SmoothingOptionsMenu()
        PressureButtons(settings: s)
        if app.tool == .cloneStamp {
            Toggle2(label: "Aligned", on: $app.cloneAligned)
            Toggle2(label: "Sample All Layers", on: $app.cloneSampleAll)
            Text("⌥-click to set source").foregroundStyle(Theme.textFaint)
        }
        if app.tool == .healing { Text("⌥-click to set source").foregroundStyle(Theme.textFaint) }
        if app.tool == .historyBrush, let d = app.activeDocument {
            Picker("Source", selection: Binding(get: { app.historyBrushSource ?? 0 }, set: { app.historyBrushSource = $0 })) {
                ForEach(Array(d.history.enumerated()), id: \.offset) { i, h in Text("\(i). \(h.name)").tag(i) }
            }.frame(width: 200)
        }
    }
}

struct RetouchOptions: View {
    @Bindable var app = AppModel.shared
    @State private var showBrushes = false
    var body: some View {
        // each retouch tool remembers its own brush (Blur, Smudge, Dodge, …)
        let s = Binding(get: { app.activeBrushSettings }, set: { app.activeBrushSettings = $0 })
        Button { showBrushes.toggle() } label: {
            HStack(spacing: 4) {
                BrushTipPreview(settings: s.wrappedValue).frame(width: 22, height: 22)
                Text("\(Int(s.wrappedValue.size))").font(Theme.mono)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showBrushes, arrowEdge: .bottom) { BrushSettingsView(settings: s).frame(width: 300).padding(10) }
        switch app.tool {
        case .dodge, .burn:
            Picker("Range", selection: $app.retouch.range) {
                ForEach(RetouchRange.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.frame(width: 150)
            CompactSlider(label: "Exposure", value: $app.retouch.exposure, range: 0.01...1, unit: "%", scale: 100)
        case .sponge:
            Picker("Mode", selection: $app.retouch.spongeSaturate) {
                Text("Desaturate").tag(false)
                Text("Saturate").tag(true)
            }.frame(width: 150)
            CompactSlider(label: "Flow", value: $app.retouch.strength, range: 0.01...1, unit: "%", scale: 100)
        case .smudge:
            CompactSlider(label: "Strength", value: $app.retouch.strength, range: 0.01...1, unit: "%", scale: 100)
            Toggle2(label: "Finger Painting", on: $app.retouch.fingerPainting)
        default:
            CompactSlider(label: "Strength", value: $app.retouch.strength, range: 0.01...1, unit: "%", scale: 100)
        }
        CompactSlider(label: "Smoothing", value: s.smoothing, range: 0...0.95, unit: "%", scale: 100)
        SmoothingOptionsMenu()
        PressureButtons(settings: s, opacityHelp: "Pressure controls strength")
    }
}

/// Photoshop's Smoothing options (gear next to Smoothing): pulled-string mode and catch-up behaviour.
struct SmoothingOptionsMenu: View {
    @Bindable var tablet = TabletSettings.shared
    var body: some View {
        Menu {
            Toggle("Pulled String Mode", isOn: $tablet.prefs.smoothing.pulledString)
            Toggle("Stroke Catch-up", isOn: $tablet.prefs.smoothing.strokeCatchUp)
            Toggle("Catch-up on Stroke End", isOn: $tablet.prefs.smoothing.catchUpOnEnd)
            Toggle("Adjust for Zoom", isOn: $tablet.prefs.smoothing.adjustForZoom)
        } label: { Image(systemName: "gearshape") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Smoothing options")
    }
}

/// The options-bar pressure buttons: on, pen pressure drives size / opacity whatever the Brush Settings panel says.
struct PressureButtons: View {
    let settings: Binding<BrushSettings>
    var opacityHelp = "Pressure controls opacity (overrides Brush Settings)"
    var body: some View {
        IconButton(symbol: "hand.draw", help: "Pressure controls size (overrides Brush Settings)", active: settings.wrappedValue.pressureSize) { settings.wrappedValue.pressureSize.toggle() }
        IconButton(symbol: "circle.lefthalf.striped.horizontal", help: opacityHelp, active: settings.wrappedValue.pressureOpacity) { settings.wrappedValue.pressureOpacity.toggle() }
    }
}

struct GradientOptions: View {
    @Bindable var app = AppModel.shared
    @State private var showPresets = false
    var body: some View {
        Button { showPresets.toggle() } label: {
            GradientSwatch(gradient: app.gradientTool.gradient, reverse: app.gradientTool.reverse).frame(width: 110, height: 20)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPresets, arrowEdge: .bottom) {
            GradientPresetGrid(selected: $app.gradientTool.gradient).padding(10).frame(width: 260)
        }
        Button("Edit…") { app.dialog = .gradientEditor }.buttonStyle(PanelButtonStyle())
        HStack(spacing: 2) {
            ForEach(GradientType.allCases) { t in
                IconButton(symbol: icon(t), help: "\(t.displayName) Gradient", active: app.gradientTool.type == t) { app.gradientTool.type = t }
            }
        }
        Text("Mode").foregroundStyle(Theme.textDim)
        BlendModePicker(mode: $app.gradientTool.blendMode, width: 100)
        CompactSlider(label: "Opacity", value: $app.gradientTool.opacity, range: 0...1, unit: "%", scale: 100)
        Toggle2(label: "Reverse", on: $app.gradientTool.reverse)
        Toggle2(label: "FG/BG colors", on: $app.gradientTool.useForegroundBackground)
    }
    func icon(_ t: GradientType) -> String {
        switch t {
        case .linear: return "rectangle.lefthalf.inset.filled"
        case .radial: return "circle.circle"
        case .angle: return "circle.dotted"
        case .reflected: return "rectangle.split.2x1"
        case .diamond: return "diamond"
        }
    }
}

struct GradientPresetGrid: View {
    @Binding var selected: ColorGradient
    @Bindable var app = AppModel.shared
    /// In a panel: as many columns as fit its width (four need 226 pt), elsewhere four.
    @Environment(\.panelWidth) private var panelWidth
    private var adaptive: Bool { panelWidth.isFinite }
    var body: some View {
        LazyVGrid(columns: adaptive ? [GridItem(.adaptive(minimum: 52, maximum: 52), spacing: 6)] : Array(repeating: GridItem(.fixed(52), spacing: 6), count: 4),
                  alignment: adaptive ? .leading : .center, spacing: 6) {
            ForEach(app.gradients) { g in
                GradientSwatch(gradient: g)
                    .frame(width: 52, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected.id == g.id ? Theme.accent : .clear, lineWidth: 2))
                    .onTapGesture { selected = g }
                    .help(g.name)
            }
        }
    }
}

struct BucketOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        Picker("", selection: $app.bucket.usePattern) {
            Text("Foreground").tag(false)
            Text("Pattern").tag(true)
        }.labelsHidden().frame(width: 110)
        if app.bucket.usePattern { PatternPicker(patternID: $app.bucket.patternID) }
        Text("Mode").foregroundStyle(Theme.textDim)
        BlendModePicker(mode: $app.bucket.blendMode, width: 100)
        CompactSlider(label: "Opacity", value: $app.bucket.opacity, range: 0...1, unit: "%", scale: 100)
        CompactSlider(label: "Tolerance", value: $app.bucket.tolerance, range: 0...255)
        Toggle2(label: "Anti-alias", on: $app.bucket.antialias)
        Toggle2(label: "Contiguous", on: $app.bucket.contiguous)
        Toggle2(label: "All Layers", on: $app.bucket.sampleAllLayers)
    }
}

struct PatternPicker: View {
    @Binding var patternID: String
    @Bindable var app = AppModel.shared
    @State private var open = false
    var body: some View {
        let all = PatternDef.builtIn + app.customPatterns
        Button { open.toggle() } label: {
            PatternThumb(pattern: all.first { $0.id == patternID }).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 5), spacing: 6) {
                ForEach(all) { p in
                    PatternThumb(pattern: p).frame(width: 40, height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(p.id == patternID ? Theme.accent : .clear, lineWidth: 2))
                        .onTapGesture { patternID = p.id; open = false }
                        .help(p.name)
                }
            }.padding(10)
        }
    }
}

struct PatternThumb: View {
    let pattern: PatternDef?
    var body: some View {
        if let p = pattern {
            Image(decorative: p.image.makeCGImage(), scale: 1).resizable(resizingMode: .tile)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.4), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 2).fill(Theme.fieldBG)
        }
    }
}

struct PathOperationMenu: View {
    let current: PathOperation?
    let allowNew: Bool
    let onPick: (PathOperation?) -> Void
    var showMerge = true

    static func symbol(_ op: PathOperation?) -> String {
        switch op {
        case nil: return "square"
        case .combine?: return "square.on.square"
        case .subtract?: return "square.on.square.dashed"
        case .intersect?: return "square.on.square.intersection.dashed"
        case .exclude?: return "square.split.diagonal.2x2"
        }
    }
    static func name(_ op: PathOperation?) -> String {
        switch op {
        case nil: return "New Layer"
        case .combine?: return "Combine Shapes"
        case .subtract?: return "Subtract Front Shape"
        case .intersect?: return "Intersect Shape Areas"
        case .exclude?: return "Exclude Overlapping Shapes"
        }
    }

    var body: some View {
        Menu {
            if allowNew { Button(PathOperationMenu.name(nil)) { onPick(nil) } }
            ForEach(PathOperation.allCases, id: \.self) { op in Button(PathOperationMenu.name(op)) { onPick(op) } }
            if showMerge {
                Divider()
                Button("Merge Shape Components") { VectorEditing.mergeComponents() }
            }
        } label: {
            Image(systemName: PathOperationMenu.symbol(current))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Path operations: " + PathOperationMenu.name(current))
    }
}

struct PathOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let _ = app.sessionTick
        PathOperationMenu(current: VectorEditing.currentComponentOperation, allowNew: false) { op in if let op { VectorEditing.setComponentOperation(op) } }
        Button("Make Selection") { AppActions.selectionFromPath() }.buttonStyle(PanelButtonStyle())
        Button("Fill Path") { AppActions.fillPath() }.buttonStyle(PanelButtonStyle())
        Button("Stroke Path") { AppActions.strokePath() }.buttonStyle(PanelButtonStyle())
        Button("Make Shape") { AppActions.shapeFromPath() }.buttonStyle(PanelButtonStyle())
        Text("⌥-click an anchor to toggle smooth/corner · Delete removes anchors · Esc deselects the path").foregroundStyle(Theme.textFaint)
    }
}

struct TextOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let editingLayer = app.activeDocument?.activeLayer?.text != nil
        FontPicker(fontName: Binding(get: { editingLayer ? (app.activeDocument?.activeLayer?.text?.fontName ?? app.textTool.fontName) : app.textTool.fontName },
                                     set: { v in app.textTool.fontName = v; TextOptions.updateActiveText { $0.fontName = v } }))
        NumberField(label: "", value: Binding(get: { editingLayer ? (app.activeDocument?.activeLayer?.text?.fontSize ?? 48) : app.textTool.fontSize },
                                              set: { v in app.textTool.fontSize = max(1, v); TextOptions.updateActiveText { $0.fontSize = max(1, v) } }), width: 44)
        Text("px").foregroundStyle(Theme.textFaint)
        HStack(spacing: 2) {
            ForEach(TextAlign.allCases, id: \.self) { a in
                IconButton(symbol: a == .left ? "text.alignleft" : a == .center ? "text.aligncenter" : a == .right ? "text.alignright" : "text.justify",
                           help: a.rawValue.capitalized, active: (app.activeDocument?.activeLayer?.text?.alignment ?? app.textTool.alignment) == a) {
                    app.textTool.alignment = a
                    TextOptions.updateActiveText { $0.alignment = a }
                }
            }
        }
        ColorWell(color: Binding(get: { app.activeDocument?.activeLayer?.text?.color ?? app.foreground },
                                 set: { c in app.foreground = c; TextOptions.updateActiveText { $0.color = c } }), size: 18)
        TextOptionsExtras()
        TypePathHint()
        if app.textEditingActive {
            Button { AppActions.canvas?.cancelCurrentTool() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
            Button { AppActions.canvas?.commitCurrentTool() } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }.buttonStyle(.plain)
        }
    }

    static func updateActiveText(_ body: (inout TextContent) -> Void) {
        TypeEdit.update(body)   // selection while editing, else the whole layer (UI/Panels/TypePanels.swift)
    }
}

struct FontPicker: View {
    @Binding var fontName: String
    /// In panels: the style menu goes under the family menu when the column is too narrow for both.
    var wraps = false
    var body: some View {
        if wraps {
            WrappingHStack(spacing: 4, lineSpacing: 4) { menus }
        } else {
            HStack(spacing: 4) { menus }
        }
    }

    @ViewBuilder private var menus: some View {
        let family = NSFont(name: fontName, size: 12)?.familyName ?? fontName
        Menu {
            ForEach(FontCatalog.families, id: \.self) { f in
                Button(f) {
                    if let first = FontCatalog.members(f).first { fontName = first.0 }
                }
            }
        } label: { Text(family).lineLimit(1) }
            .menuStyle(.borderlessButton).frame(width: 150)
        Menu {
            ForEach(FontCatalog.members(family), id: \.0) { m in
                Button(m.1) { fontName = m.0 }
            }
        } label: { Text(FontCatalog.members(family).first { $0.0 == fontName }?.1 ?? "Regular").lineLimit(1) }
            .menuStyle(.borderlessButton).frame(width: 90)
    }
}

enum FontCatalog {
    static let families: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    private static var memberCache: [String: [(String, String)]] = [:]
    static func members(_ family: String) -> [(String, String)] {
        if let c = memberCache[family] { return c }
        let m = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { arr -> (String, String)? in
            guard let ps = arr[0] as? String, let style = arr[1] as? String else { return nil }
            return (ps, style)
        }
        memberCache[family] = m
        return m
    }
}

struct ShapeOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        ToolModePicker(tool: app.tool)
        switch app.shapeTool.mode {
        case .shape:
            ShapeFillStrokeControls()
            ShapeSizeFields()
        case .path:
            EmptyView()   // Make: Selection… / Mask / Shape come with the mode picker; nothing is painted, so no Fill / Stroke
        case .pixels:
            ShapePixelsOptions()
        }
        if app.shapeTool.mode != .pixels {
            PathOperationMenu(current: app.shapeTool.operation, allowNew: true) { app.shapeTool.operation = $0 }
            PathAlignmentMenu()
            ShapePathOptionsButton()
        }
        if app.tool == .libraryShape { ShapeLibraryPicker(id: $app.shapeTool.libraryID) }
        switch app.tool {
        case .roundedRect: NumberField(label: "Radius", value: $app.shapeTool.cornerRadius, width: 40)
        case .polygon: NumberField(label: "Sides", value: Binding(get: { Double(app.shapeTool.sides) }, set: { app.shapeTool.sides = max(3, min(100, Int($0))) }), width: 34)
        case .customShape:
            NumberField(label: "Points", value: Binding(get: { Double(app.shapeTool.sides) }, set: { app.shapeTool.sides = max(3, min(100, Int($0))) }), width: 34)
            CompactSlider(label: "Inset", value: $app.shapeTool.starRatio, range: 0.05...0.99, unit: "%", scale: 100)
        case .line: NumberField(label: "Weight", value: $app.shapeTool.lineWeight, width: 40); LineArrowOptions()
        default: EmptyView()
        }
    }
}

struct ShapeLibraryPicker: View {
    @Binding var id: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                ShapeThumb(id: id).frame(width: 18, height: 18)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
        }
        .buttonStyle(.plain)
        .help("Shape: " + (ShapeLibrary.shape(id)?.name ?? ""))
        .popover(isPresented: $open) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ShapeLibrary.categories, id: \.self) { cat in
                        Text(cat).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 6), spacing: 6) {
                            ForEach(ShapeLibrary.all.filter { $0.category == cat }) { s in
                                ShapeThumb(id: s.id)
                                    .frame(width: 40, height: 40)
                                    .padding(3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(s.id == id ? Theme.selection : Theme.fieldBG))
                                    .help(s.name)
                                    .onTapGesture { id = s.id; open = false }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 300, height: 320)
        }
    }
}

struct ShapeThumb: View {
    let id: String
    var body: some View {
        Canvas { ctx, size in
            guard let s = ShapeLibrary.shape(id) else { return }
            let side = min(size.width, size.height) * 0.9
            let r = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            let rp = s.path(in: r).resolved
            ctx.fill(Path(rp.path), with: .color(Theme.text), style: FillStyle(eoFill: rp.evenOdd))
        }
    }
}

/// None / solid / gradient / pattern chooser.
struct PaintStylePicker: View {
    @Binding var paint: PaintStyle
    var onCommit: (() -> Void)? = nil
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { PaintStyleSwatch(paint: paint).frame(width: 30, height: 18) }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                PaintStylePopoverContent(paint: $paint)
                    .onDisappear { onCommit?() }
            }
    }
}

/// The Fill / Stroke popover: the editor at its natural size (the popover is sized from it), never narrower than the
/// colour picker, so switching between solid, gradient and pattern keeps the width; opaque background.
struct PaintStylePopoverContent: View {
    @Binding var paint: PaintStyle
    static let minWidth: CGFloat = 300
    var body: some View {
        PaintStyleEditor(paint: $paint)
            .frame(minWidth: Self.minWidth, alignment: .topLeading)
            .colorPopoverContent()
    }
}

struct PaintStyleSwatch: View {
    let paint: PaintStyle
    var body: some View {
        ZStack {
            switch paint {
            case .none:
                Rectangle().fill(Color.white)
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 30, y: 18)) }.stroke(Color.red, lineWidth: 1.5)
            case .color(let c):
                CheckerBackground(size: 3)
                Rectangle().fill(Color(nsColor: c.nsColor))
            case .gradient(let g):
                GradientSwatch(gradient: g.gradient, reverse: g.reverse)
            case .pattern(let id, _):
                PatternThumb(pattern: PatternLibrary.pattern(id: id, custom: AppModel.shared.customPatterns))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.45), lineWidth: 0.5))
    }
}

struct PaintStyleEditor: View {
    @Binding var paint: PaintStyle
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                IconButton(symbol: "slash.circle", help: "No Color", active: paint.isNone) { paint = .none }
                IconButton(symbol: "square.fill", help: "Solid Color", active: paint.solidColor != nil) { paint = .color(paint.solidColor ?? AppModel.shared.foreground) }
                IconButton(symbol: "square.fill.and.line.vertical.and.square", help: "Gradient", active: { if case .gradient = paint { return true }; return false }()) {
                    paint = .gradient(GradientFill(gradient: .twoColor(AppModel.shared.foreground, AppModel.shared.background)))
                }
                IconButton(symbol: "square.grid.3x3.fill", help: "Pattern", active: { if case .pattern = paint { return true }; return false }()) {
                    paint = .pattern(id: "checker", scale: 1)
                }
            }
            switch paint {
            case .none:
                Text("No fill").foregroundStyle(Theme.textDim)
            case .color:
                ColorPickerView(color: Binding(get: { paint.solidColor ?? .black }, set: { paint = .color($0) }), title: "Color", showAlpha: true)
            case .gradient(let gf):
                GradientFillEditor(fill: Binding(get: { gf }, set: { paint = .gradient($0) }))
            case .pattern(let id, let scale):
                WrappingHStack {
                    PatternPicker(patternID: Binding(get: { id }, set: { paint = .pattern(id: $0, scale: scale) }))
                    ValueSlider(label: "Scale", value: Binding(get: { scale * 100 }, set: { paint = .pattern(id: id, scale: $0 / 100) }), range: 1...1000, unit: "%", labelWidth: 40)
                }
            }
        }
    }
}

struct GradientFillEditor: View {
    @Binding var fill: GradientFill
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GradientPresetGrid(selected: $fill.gradient)
            GradientStopsEditor(gradient: $fill.gradient)
            Picker("Style", selection: $fill.type) { ForEach(GradientType.allCases) { Text($0.displayName).tag($0) } }
            WrappingHStack {
                Text("Angle").foregroundStyle(Theme.textDim)
                AngleDial(angle: $fill.angle)
                NumberField(label: "", value: $fill.angle, width: 40)
                Text("°").foregroundStyle(Theme.textFaint)
                Toggle2(label: "Reverse", on: $fill.reverse)
            }
            ValueSlider(label: "Scale", value: Binding(get: { fill.scale * 100 }, set: { fill.scale = $0 / 100 }), range: 10...150, unit: "%", labelWidth: 40)
        }
    }
}

struct ViewOptions: View {
    var body: some View {
        Button("100%") { AppActions.actualPixels() }.buttonStyle(PanelButtonStyle())
        Button("Fit Screen") { AppActions.fitOnScreen() }.buttonStyle(PanelButtonStyle())
        Button("Fill Screen") { ZoomController.run(.fillScreen) }.buttonStyle(PanelButtonStyle())
        Button("Zoom In") { AppActions.zoomIn() }.buttonStyle(PanelButtonStyle())
        Button("Zoom Out") { AppActions.zoomOut() }.buttonStyle(PanelButtonStyle())
    }
}

// MARK: - Brush settings
// BrushTipPreview and BrushSettingsView live in UI/Panels/BrushSettingsPanel.swift.


// MARK: - New tool option groups

struct MagneticLassoOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CombineModeButtons(mode: $app.selection.combine)
        CompactSlider(label: "Feather", value: $app.selection.feather, range: 0...250, unit: " px")
        FeatherDirectionMenu(direction: $app.featherDirection)
        CompactSlider(label: "Width", value: $app.magneticWidth, range: 1...256, unit: " px")
        CompactSlider(label: "Contrast", value: $app.magneticContrast, range: 1...100, unit: "%")
        CompactSlider(label: "Frequency", value: $app.magneticFrequency, range: 0...100)
        Text("Click to start, move along an edge, click the start point or double-click to close.").foregroundStyle(Theme.textFaint)
    }
}

struct ObjectSelectOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CombineModeButtons(mode: $app.selection.combine)
        Picker("Mode", selection: $app.objectSelectMode) { ForEach(ObjectSelectMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 150)
        Button("Select Subject") { AppActions.selectSubject() }.buttonStyle(PanelButtonStyle())
        Button("Select and Mask…") { AppModel.shared.dialog = .selectAndMask }.buttonStyle(PanelButtonStyle())
    }
}

struct PatchOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CombineModeButtons(mode: $app.selection.combine)
        Picker("Patch", selection: $app.patchMode) { ForEach(PatchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 190)
        Text("Draw around an area, then drag the selection to a sample area.").foregroundStyle(Theme.textFaint)
    }
}

struct ContentAwareMoveOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CombineModeButtons(mode: $app.selection.combine)
        Picker("Mode", selection: $app.contentAwareMoveMode) { ForEach(ContentAwareMoveMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 160)
        Text("Select an object, then drag it to its new place.").foregroundStyle(Theme.textFaint)
    }
}

struct RemoveOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CompactSlider(label: "Size", value: $app.removeBrush.size, range: 1...1000, unit: " px")
        Toggle2(label: "Sample All Layers", on: $app.removeSampleAll)
        GenAIRemoveModeOption()
        if !GenAISettings.shared.data.removeUsesCloud { NeuralRemoveOptions() }
        Text("Paint over what you want to remove.").foregroundStyle(Theme.textFaint)
    }
}

struct ColorReplacementOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CompactSlider(label: "Size", value: $app.colorReplaceBrush.size, range: 1...1000, unit: " px")
        PressureButtons(settings: $app.colorReplaceBrush)
        Picker("Mode", selection: $app.colorReplace.mode) {
            Text("Hue").tag(BlendMode.hue); Text("Saturation").tag(BlendMode.saturation); Text("Color").tag(BlendMode.color); Text("Luminosity").tag(BlendMode.luminosity)
        }.frame(width: 150)
        Picker("Sampling", selection: $app.colorReplace.sampling) { ForEach(ColorSampling.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 200)
        CompactSlider(label: "Tolerance", value: $app.colorReplace.tolerance, range: 1...100, unit: "%")
    }
}

struct MixerOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        CompactSlider(label: "Size", value: $app.mixerBrushSettings.size, range: 1...1000, unit: " px")
        PressureButtons(settings: $app.mixerBrushSettings)
        CompactSlider(label: "Smoothing", value: $app.mixerBrushSettings.smoothing, range: 0...0.95, unit: "%", scale: 100)
        Toggle2(label: "Load after stroke", on: $app.mixer.loadEachStroke)
        Toggle2(label: "Clean after stroke", on: $app.mixer.cleanEachStroke)
        CompactSlider(label: "Wet", value: $app.mixer.wet, range: 0...100, unit: "%")
        CompactSlider(label: "Load", value: $app.mixer.load, range: 1...100, unit: "%")
        CompactSlider(label: "Mix", value: $app.mixer.mix, range: 0...100, unit: "%")
        CompactSlider(label: "Flow", value: $app.mixerBrushSettings.flow, range: 0.01...1, unit: "%", scale: 100)
        Toggle2(label: "Sample All Layers", on: $app.mixer.sampleAll)
    }
}


/// Options for Warp / Puppet Warp / Perspective Warp / Content-Aware Scale sessions.
struct InteractiveSessionOptions: View {
    let session: InteractiveSession
    @Bindable var app = AppModel.shared

    func bump() { app.sessionTick += 1 }

    var body: some View {
        let _ = app.sessionTick
        Text(session.title).font(Theme.fontBold)
        Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
        if let sw = session as? SplitWarpSession {
            SplitWarpOptions(w: sw, bump: bump)
        } else if let w = session as? WarpSession {
            Picker("Grid", selection: Binding(get: { w.gridSize }, set: { w.gridSize = $0; bump() })) {
                Text("3 × 3").tag(4); Text("4 × 4").tag(5); Text("5 × 5").tag(6)
            }.frame(width: 110)
            Picker("Warp", selection: Binding(get: { w.style }, set: { w.style = $0; bump() })) {
                Text("Custom").tag(WarpStyle.none)
                ForEach(WarpStyle.allCases.filter { $0 != .none }) { Text($0.displayName).tag($0) }
            }.frame(width: 160)
            if w.style != .none {
                CompactSlider(label: "Bend", value: Binding(get: { w.bend * 100 }, set: { w.bend = $0 / 100; bump() }), range: -100...100, unit: "%")
                CompactSlider(label: "H", value: Binding(get: { w.hDistort * 100 }, set: { w.hDistort = $0 / 100; bump() }), range: -100...100, unit: "%")
                CompactSlider(label: "V", value: Binding(get: { w.vDistort * 100 }, set: { w.vDistort = $0 / 100; bump() }), range: -100...100, unit: "%")
            } else {
                Text("Drag grid points or inside the mesh").foregroundStyle(Theme.textFaint)
            }
        } else if let p = session as? PuppetWarpSession {
            Picker("Density", selection: Binding(get: { p.density }, set: { p.density = $0; bump() })) {
                Text("Fewer Points").tag(20); Text("Normal").tag(36); Text("More Points").tag(56)
            }.frame(width: 170)
            CompactSlider(label: "Rigidity", value: Binding(get: { p.rigidity }, set: { p.rigidity = $0; bump() }), range: 0.5...3)
            Toggle2(label: "Show Mesh", on: Binding(get: { p.showMesh }, set: { p.showMesh = $0; bump(); AppActions.canvas?.overlay.needsDisplay = true }))
            Text("Click to add pins, drag to deform · ⌥-click removes a pin").foregroundStyle(Theme.textFaint)
        } else if let pw = session as? PerspectiveWarpSession {
            Picker("", selection: Binding(get: { pw.mode }, set: { pw.mode = $0; bump(); AppActions.canvas?.overlay.needsDisplay = true })) {
                ForEach(PerspectiveWarpSession.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            if pw.mode == .layout {
                Button("Split Vertically") { pw.split(horizontal: true); bump(); AppActions.canvas?.overlay.needsDisplay = true }.buttonStyle(PanelButtonStyle())
                Button("Split Horizontally") { pw.split(horizontal: false); bump(); AppActions.canvas?.overlay.needsDisplay = true }.buttonStyle(PanelButtonStyle())
                Text("Position the plane corners on the object, then switch to Warp").foregroundStyle(Theme.textFaint)
            } else {
                Text("Drag corners to change perspective · ⇧ constrains").foregroundStyle(Theme.textFaint)
            }
        } else if let cas = session as? ContentAwareScaleSession {
            CompactSlider(label: "Amount", value: Binding(get: { cas.amount }, set: { cas.amount = $0; bump() }), range: 0...100, unit: "%")
            Picker("Protect", selection: Binding(get: { cas.protectChannel }, set: { cas.protectChannel = $0; bump() })) {
                Text("None").tag(UUID?.none)
                ForEach(app.activeDocument?.state.alphaChannels ?? []) { ch in Text(ch.name).tag(UUID?.some(ch.id)) }
            }.frame(width: 160)
        }
        Button { AppActions.canvas?.cancelCurrentTool() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel (Esc)")
        Button { AppActions.canvas?.commitCurrentTool() } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }.buttonStyle(.plain).help("Apply (Return)")
    }
}
