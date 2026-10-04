import SwiftUI

struct PreferencesDialog: View {
    @Bindable var app = AppModel.shared
    @State private var section = Workflow2PrefsState.initialSection() ?? GenAIPrefsState.initialSection()
    private let sections = Workflow2PrefsState.sections

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preferences").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.self) { s in
                        Text(s).padding(.horizontal, 8).padding(.vertical, 4).frame(width: 150, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4).fill(section == s ? Theme.selection : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { section = s }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) { content }
                    .frame(width: 340, alignment: .topLeading)
            }
            .frame(minHeight: 260, alignment: .top)
            HStack {
                Button("Reset All") { app.prefs = Preferences() }.buttonStyle(PanelButtonStyle())
                Spacer()
                Button("OK") { app.dialog = nil; AppActions.canvas?.setNeedsRender() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .onChange(of: app.prefs) { _, _ in AppActions.canvas?.setNeedsRender(); AppActions.canvas?.overlay.needsDisplay = true }
    }

    @ViewBuilder var content: some View {
        switch section {
        case "General":
            ValueSlider(label: "History States", value: Binding(get: { Double(app.prefs.historyStates) }, set: { app.prefs.historyStates = Int($0) }), range: 5...500, step: 1, labelWidth: 110)
            Toggle2(label: "Fit new/opened documents on screen", on: $app.prefs.autoFitOnOpen)
            MaskTargetPreference()
        case "Interface":
            Picker("Color Theme", selection: $app.prefs.theme) { ForEach(InterfaceTheme.allCases) { Text($0.rawValue).tag($0) } }
            Toggle2(label: "Show Tool Tips", on: $app.prefs.showToolTips)
            Text("Theme changes apply to panels immediately.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        case "Cursors":
            Picker("Painting Cursors", selection: $app.prefs.brushCursor) { ForEach(BrushCursorStyle.allCases) { Text($0.rawValue).tag($0) } }
            Toggle2(label: "Show Crosshair in Brush Tip", on: $app.prefs.showCrosshairInBrushTip)
        case "Transparency & Guides":
            ValueSlider(label: "Checker Size", value: $app.prefs.checkerSize, range: 2...32, step: 1, unit: "px", labelWidth: 110)
            HStack { Text("Guides").foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading); ColorWell(color: $app.prefs.guideColor) }
            HStack { Text("Grid").foregroundStyle(Theme.textDim).frame(width: 110, alignment: .leading); ColorWell(color: $app.prefs.gridColor) }
            ValueSlider(label: "Gridline Every", value: $app.prefs.gridSpacing, range: 1...500, unit: " " + app.prefs.rulerUnits.short, labelWidth: 110)
            ValueSlider(label: "Subdivisions", value: Binding(get: { Double(app.prefs.gridSubdivisions) }, set: { app.prefs.gridSubdivisions = Int($0) }), range: 1...20, step: 1, labelWidth: 110)
        case "Generative AI":
            GenAIPreferencesSection()
        case "Radial Menu":
            RadialMenuPreferencesSection()
        case "Units":
            Picker("Rulers", selection: $app.prefs.rulerUnits) { ForEach(RulerUnit.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Type", selection: $app.prefs.typeUnits) { ForEach(RulerUnit.allCases.filter { $0 != .percent }) { Text($0.rawValue).tag($0) } }
            Text("Resolution comes from Image › Image Size (currently \(Int(app.activeDocument?.state.resolution ?? 72)) ppi).").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        case "AI Models":
            ModelsPreferencesView()
        case "Artboards":
            ArtboardPreferencesSection()
        case "Workflow":
            Workflow2PrefsSection()
        default:
            Toggle2(label: "Cache composite for large documents", on: $app.prefs.cacheLargeDocuments)
            ValueSlider(label: "Large Doc Threshold", value: $app.prefs.largeDocumentThreshold, range: 1...100, step: 1, unit: " MP", labelWidth: 120)
            Text("Memory in use: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB installed").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}
