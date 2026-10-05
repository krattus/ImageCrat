import SwiftUI
import ImageCratCore

/// Options bar for the ToolsModule tools.
struct ExtraToolOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared

    var body: some View {
        switch app.tool {
        case .artboard: ArtboardOptions()
        case .selectionBrush: SelectionBrushOptions()
        case .perspectiveCrop: PerspectiveCropOptions()
        case .slice, .sliceSelect: SliceOptions()
        case .frame: FrameOptions()
        case .colorSampler: ColorSamplerOptions()
        case .ruler: RulerOptions()
        case .note: NoteOptions()
        case .count: CountOptions()
        case .patternStamp: PatternStampOptions()
        case .artHistoryBrush: ArtHistoryOptions()
        case .backgroundEraser: BackgroundEraserOptions()
        case .curvaturePen:
            ToolModePicker(tool: app.tool)
            if app.penMode == .shape { ShapeFillStrokeControls() }
            Text("Click to add points; the curve passes through them. Double-click a point for a corner; click the first point to close.").foregroundStyle(Theme.textDim)
        case .addAnchor: Text("Click a path segment to add an anchor point.").foregroundStyle(Theme.textDim)
        case .deleteAnchor: Text("Click an anchor point to delete it.").foregroundStyle(Theme.textDim)
        case .convertPoint: Text("Click an anchor to make a corner; drag from it to pull out smooth handles; drag a handle to break it.").foregroundStyle(Theme.textDim)
        case .triangle:
            ShapeOptions()
            NumberField(label: "Radius", value: $ts.triangleRadius, width: 40)
        case .typeMaskHorizontal, .typeMaskVertical:
            TextOptions()
            Text("Type to create a selection from the text outline.").foregroundStyle(Theme.textFaint)
        default: EmptyView()
        }
    }
}

/// Brush tip button + popover for tools with their own brush settings.
struct ExtraBrushPicker: View {
    let settings: Binding<BrushSettings>
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                BrushTipPreview(settings: settings.wrappedValue).frame(width: 22, height: 22)
                Text("\(Int(settings.wrappedValue.size))").font(Theme.mono)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { BrushSettingsView(settings: settings).frame(width: 300).padding(10) }
    }
}

struct SelectionBrushOptions: View {
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        ExtraBrushPicker(settings: $ts.selectionBrush)
        HStack(spacing: 2) {
            IconButton(symbol: "plus.square", help: "Add to selection", active: !ts.selectionBrushSubtract) { ts.selectionBrushSubtract = false }
            IconButton(symbol: "minus.square", help: "Subtract from selection (Option)", active: ts.selectionBrushSubtract) { ts.selectionBrushSubtract = true }
        }
        CompactSlider(label: "Hardness", value: $ts.selectionBrush.hardness, range: 0...1, unit: "%", scale: 100)
        Text("Overlay").foregroundStyle(Theme.textDim)
        ColorWell(color: $ts.selectionOverlayColor, size: 18)
        CompactSlider(label: "Opacity", value: $ts.selectionOverlayOpacity, range: 0.05...1, unit: "%", scale: 100)
    }
}

struct PerspectiveCropOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        let _ = app.sessionTick
        Toggle2(label: "Show Grid", on: $ts.perspectiveShowGrid)
        Toggle2(label: "Delete Cropped Pixels", on: $app.crop.deleteCropped)
        if let t = AppActions.canvas?.tool(for: .perspectiveCrop) as? PerspectiveCropTool, let q = t.quad {
            let (w, h) = PerspectiveCropTool.outputSize(q)
            Text("\(w) × \(h) px").font(Theme.mono).foregroundStyle(Theme.textDim)
        } else {
            Text("Drag a box, then move the corners onto the edges of the plane.").foregroundStyle(Theme.textFaint)
        }
        Button { AppActions.canvas?.cancelCurrentTool() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Cancel (Esc)")
        Button { AppActions.canvas?.commitCurrentTool() } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }.buttonStyle(.plain).help("Commit (Return)")
    }
}

struct ColorSamplerOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        Picker("Sample Size", selection: $ts.colorSamplerSize) {
            Text("Point Sample").tag(1)
            Text("3 by 3 Average").tag(3)
            Text("5 by 5 Average").tag(5)
            Text("11 by 11 Average").tag(11)
        }.frame(width: 220)
        Button("Clear All") {
            if let d = app.activeDocument, !d.state.toolData.colorSamplers.isEmpty { d.state.toolData.colorSamplers = []; d.commit("Delete Color Samplers") }
        }.buttonStyle(PanelButtonStyle())
        Text("Click to add (max 10) · drag to move · ⌥-click deletes · values in the Info panel").foregroundStyle(Theme.textFaint)
    }
}

struct RulerOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let _ = app.sessionTick
        if let d = app.activeDocument {
            Text(RulerTool.line(d) != nil ? RulerTool.info(d) : "Drag to measure distance and angle.").font(Theme.mono).foregroundStyle(Theme.textDim)
            Button("Straighten Layer") { RulerTool.straightenLayer(d) }.buttonStyle(PanelButtonStyle()).disabled(RulerTool.line(d) == nil)
            Button("Clear") { ToolsSettings.shared.rulerLines[d.id] = nil; app.sessionTick += 1; ToolsModule.refreshCanvas() }.buttonStyle(PanelButtonStyle())
            Button("Record") { MeasurementActions.record() }.buttonStyle(PanelButtonStyle())
        }
    }
}

struct NoteOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        Text("Author").foregroundStyle(Theme.textDim)
        TextField("", text: $ts.noteAuthor).textFieldStyle(.roundedBorder).frame(width: 130)
        ColorWell(color: $ts.noteColor, size: 18)
        Button("Clear All") {
            if let d = app.activeDocument, !d.state.toolData.notes.isEmpty { d.state.toolData.notes = []; ts.selectedNoteID = nil; d.commit("Clear Notes") }
        }.buttonStyle(PanelButtonStyle())
        Button("Show Notes Panel") { WorkspaceManager.shared.showPanel("notes") }.buttonStyle(PanelButtonStyle())
    }
}

struct PatternStampOptions: View {
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        ExtraBrushPicker(settings: $ts.patternStampBrush)
        Text("Mode").foregroundStyle(Theme.textDim)
        BlendModePicker(mode: $ts.patternStampBrush.blendMode, width: 100)
        CompactSlider(label: "Opacity", value: $ts.patternStampBrush.opacity, range: 0...1, unit: "%", scale: 100)
        CompactSlider(label: "Flow", value: $ts.patternStampBrush.flow, range: 0.01...1, unit: "%", scale: 100)
        PatternPicker(patternID: $ts.patternID)
        Toggle2(label: "Aligned", on: $ts.patternAligned)
        Toggle2(label: "Impressionist", on: $ts.patternImpressionist)
    }
}

struct ArtHistoryOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        ExtraBrushPicker(settings: $ts.artHistoryBrush)
        Text("Mode").foregroundStyle(Theme.textDim)
        BlendModePicker(mode: $ts.artHistoryBrush.blendMode, width: 100)
        CompactSlider(label: "Opacity", value: $ts.artHistoryBrush.opacity, range: 0...1, unit: "%", scale: 100)
        Picker("Style", selection: $ts.artStyle) {
            ForEach(ArtHistoryStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.frame(width: 170)
        CompactSlider(label: "Area", value: $ts.artArea, range: 1...500, unit: " px")
        CompactSlider(label: "Tolerance", value: $ts.artTolerance, range: 0...100, unit: "%")
        if let d = app.activeDocument {
            Picker("Source", selection: Binding(get: { app.historyBrushSource ?? 0 }, set: { app.historyBrushSource = $0 })) {
                ForEach(Array(d.history.enumerated()), id: \.offset) { i, h in Text("\(i). \(h.name)").tag(i) }
            }.frame(width: 180)
        }
    }
}

struct BackgroundEraserOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        ExtraBrushPicker(settings: $ts.bgEraserBrush)
        HStack(spacing: 2) {
            IconButton(symbol: "eyedropper.halffull", help: "Sampling: Continuous", active: ts.bgSampling == .continuous) { ts.bgSampling = .continuous }
            IconButton(symbol: "eyedropper", help: "Sampling: Once", active: ts.bgSampling == .once) { ts.bgSampling = .once }
            IconButton(symbol: "square.fill.on.square", help: "Sampling: Background Swatch", active: ts.bgSampling == .backgroundSwatch) { ts.bgSampling = .backgroundSwatch }
        }
        Picker("Limits", selection: $ts.bgLimits) {
            ForEach(EraserLimits.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.frame(width: 170)
        CompactSlider(label: "Tolerance", value: $ts.bgTolerance, range: 0...100, unit: "%")
        Toggle2(label: "Protect Foreground Color", on: $ts.bgProtectForeground)
    }
}
