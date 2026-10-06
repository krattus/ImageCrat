import SwiftUI
import ImageCratCore

// MARK: - Tip thumbnails

struct BrushTipPreview: View {
    let settings: BrushSettings
    var body: some View {
        Canvas { ctx, size in
            let d = min(size.width, size.height) - 2
            if let m = BrushTips.mask(diameter: 64, hardness: settings.hardness, roundness: settings.roundness, angle: settings.angle, tipID: settings.tipID),
               let img = BrushTips.colored(m, color: .white) {
                ctx.draw(Image(decorative: img, scale: 1), in: CGRect(x: (size.width - d) / 2, y: (size.height - d) / 2, width: d, height: d))
            }
        }
    }
}

// MARK: - Stroke preview

enum BrushStrokePreview {
    /// Renders an S-shaped stroke with a pressure taper using the real dynamics engine.
    static func render(_ settings: BrushSettings, width: Int, height: Int, scale: Int = 2,
                       fg: RGBA = RGBA(gray: 0.92), bg: RGBA = RGBA(hex: "4A90E2")!) -> CGImage {
        let w = width * scale, h = height * scale
        var s = settings
        let maxSize = Double(height) * 0.42
        let target = min(s.size, maxSize) * Double(scale)
        let f = target / max(0.01, s.size)
        s.size = target
        s.dynamics.dualSize = max(1, s.dynamics.dualSize * f)
        s.dynamics.textureScale *= Double(scale)
        s.smoothing = 0
        s.opacity = 1
        let buf = PixelBuffer(width: w, height: h)
        let eng = BrushDynamicsEngine(settings: s, target: buf, origin: .zero, paint: .dynamic(fg: fg, bg: bg), seed: 7)
        let steps = 70
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: Double(w) * (0.1 + 0.8 * t), y: Double(h) / 2 - sin(t * .pi * 2) * Double(h) * 0.2)
            let smp = PenSample(p: p, pressure: max(0.05, sin(t * .pi)), rotation: t * 360, wheel: 1 - t)
            if i == 0 { eng.begin(smp) } else { eng.move(smp, final: i == steps) }
        }
        _ = eng.takeDirty()
        if eng.needsPost {
            let out = PixelBuffer(width: w, height: h)
            _ = eng.postProcess(buf.bounds, source: buf, out: out)
            return out.makeCGImage()
        }
        return buf.makeCGImage()
    }
}

struct BrushStrokePreviewView: View {
    let settings: BrushSettings
    @Bindable var app = AppModel.shared
    var body: some View {
        GeometryReader { g in
            let w = max(40, Int(g.size.width)), h = max(20, Int(g.size.height))
            // Photoshop-like: the stroke is shown with the current colors on a light swatch.
            let img = BrushStrokePreview.render(settings, width: w, height: h, fg: app.foreground, bg: app.background)
            Image(decorative: img, scale: 2)
                .frame(width: g.size.width, height: g.size.height)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.9)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Tip picker

struct TipPickerGrid: View {
    @Binding var tipID: String
    @Bindable var app = AppModel.shared
    @Bindable var library = BrushLibrary.shared

    var tipIDs: [String] {
        var ids = library.tipChoices
        for id in app.customBrushTips.keys.sorted() where !ids.contains(id) { ids.append(id) }
        if !ids.contains(tipID) { ids.append(tipID) }
        return ids
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 4) {   // (lazy: an imported set can bring hundreds of tips)
                ForEach(tipIDs, id: \.self) { id in
                    BrushTipPreview(settings: BrushSettings(size: 30, hardness: 0.9, tipID: id))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 3).fill(tipID == id ? Theme.selection : Theme.fieldBG))
                        .onTapGesture { tipID = id }
                        .help(tr(library.tipName(id)))
                }
            }
        }
        .frame(height: 32)
    }
}

// MARK: - Brush Settings panel

enum BrushSettingsSection: String, CaseIterable, Identifiable {
    case tipShape = "Brush Tip Shape"
    case shape = "Shape Dynamics"
    case scattering = "Scattering"
    case texture = "Texture"
    case dual = "Dual Brush"
    case color = "Color Dynamics"
    case transfer = "Transfer"
    case pose = "Brush Pose"
    case noise = "Noise"
    case wetEdges = "Wet Edges"
    case buildUp = "Build-up"
    case smoothing = "Smoothing"
    case protectTexture = "Protect Texture"
    var id: String { rawValue }
}

struct BrushSettingsPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let s = Binding(get: { app.activeBrushSettings }, set: { app.activeBrushSettings = $0 })
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                BrushPresetHeader()
                BrushSettingsEditor(settings: s)
            }
            .padding(10)
        }
    }
}

/// The preset the current tool's settings came from, with Photoshop's modified mark and Save / Reset / New.
struct BrushPresetHeader: View {
    @Bindable var lib = BrushLibrary.shared
    @Bindable var app = AppModel.shared

    var body: some View {
        let preset = lib.activePreset
        let modified = lib.isActivePresetModified
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "paintbrush.pointed").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Text(tr(preset?.name ?? "No preset")).font(Theme.fontBold).foregroundStyle(preset == nil ? Theme.textFaint : Theme.text).lineLimit(1).truncationMode(.middle)
                if modified { Text("*").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent).help("Changed since the preset was chosen") }
                Spacer(minLength: 0)
            }
            WrappingHStack(spacing: 4) {
                Button("Save to Preset") { lib.saveChangesToActivePreset() }.buttonStyle(PanelButtonStyle())
                    .disabled(preset == nil || !modified).help("Store the current settings in “\(preset?.name ?? "")”")
                Button("Reset") { lib.resetActivePreset() }.buttonStyle(PanelButtonStyle())
                    .disabled(preset == nil || !modified).help("Go back to the preset's settings")
                Button("New Brush…") { DefineBrush.newBrushFromCurrentSettings() }.buttonStyle(PanelButtonStyle())
                    .help("Save the current settings as a new preset")
            }
        }
    }
}

/// Photoshop-style Brush Settings: section list with enable checkboxes, the selected section's options and a live stroke preview.
struct BrushSettingsEditor: View {
    @Binding var settings: BrushSettings
    @State private var section: BrushSettingsSection
    @Environment(\.panelWidth) private var panelWidth
    /// Label column (narrower in a narrow panel column, so the sliders keep some room).
    private var lw: CGFloat { panelWidth < 240 ? 76 : 86 }

    init(settings: Binding<BrushSettings>, section: BrushSettingsSection = .tipShape) {
        _settings = settings
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(BrushSettingsSection.allCases) { sec in sectionRow(sec) }
            }
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            Text(tr(section.rawValue)).font(Theme.fontBold).foregroundStyle(Theme.text)
            content(section)
            Divider()
            BrushStrokePreviewView(settings: settings).frame(height: 70)
        }
        .font(Theme.font)
    }

    // MARK: Section list

    private func enabled(_ sec: BrushSettingsSection) -> Binding<Bool>? {
        switch sec {
        case .tipShape: return nil
        case .shape: return $settings.dynamics.shapeEnabled
        case .scattering: return $settings.dynamics.scatterEnabled
        case .texture: return $settings.dynamics.textureEnabled
        case .dual: return $settings.dynamics.dualEnabled
        case .color: return $settings.dynamics.colorEnabled
        case .transfer: return $settings.dynamics.transferEnabled
        case .pose: return $settings.dynamics.poseEnabled
        case .protectTexture: return $settings.dynamics.protectTexture
        case .noise: return $settings.dynamics.noise
        case .wetEdges: return $settings.dynamics.wetEdges
        case .buildUp: return $settings.airbrush
        case .smoothing: return Binding(get: { settings.smoothing > 0 }, set: { settings.smoothing = $0 ? max(settings.smoothing, 0.1) : 0 })
        }
    }

    private func sectionRow(_ sec: BrushSettingsSection) -> some View {
        HStack(spacing: 4) {
            if let b = enabled(sec) {
                Toggle("", isOn: b).toggleStyle(.checkbox).labelsHidden().controlSize(.small)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            Text(tr(sec.rawValue)).foregroundStyle(section == sec ? Theme.text : Theme.textDim)
            Spacer()
        }
        .padding(.horizontal, 6).frame(height: 20)
        .background(section == sec ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            section = sec
            // Selecting an option-less section toggles it, like clicking its name in Photoshop.
            if [.noise, .wetEdges, .buildUp, .protectTexture].contains(sec), let b = enabled(sec) { b.wrappedValue.toggle() }
        }
    }

    // MARK: Controls

    private func pct(_ label: String, _ kp: WritableKeyPath<BrushSettings, Double>, _ range: ClosedRange<Double> = 0...100) -> some View {
        ValueSlider(label: label, value: Binding(get: { settings[keyPath: kp] * 100 }, set: { settings[keyPath: kp] = $0 / 100 }),
                    range: range, unit: "%", labelWidth: lw)
    }

    private func control(_ kp: WritableKeyPath<BrushSettings, ControlSetting>, _ options: [BrushControl]) -> some View {
        WrappingHStack(spacing: 6) {
            Text("Control").foregroundStyle(Theme.textDim).frame(width: lw, alignment: .leading)
            Picker("", selection: Binding(get: { settings[keyPath: kp].source }, set: { settings[keyPath: kp].source = $0 })) {
                ForEach(options) { Text(tr($0.displayName)).tag($0) }
            }.labelsHidden().frame(minWidth: 70, maxWidth: 120)
            if settings[keyPath: kp].source == .fade {
                NumberField(label: "", value: Binding(get: { settings[keyPath: kp].fadeSteps }, set: { settings[keyPath: kp].fadeSteps = max(1, min(9999, $0)) }), width: 40)
                    .help("Fade steps")
            }
        }
    }

    private func modePicker(_ kp: WritableKeyPath<BrushSettings, BrushMaskMode>, _ modes: [BrushMaskMode]) -> some View {
        HStack(spacing: 6) {
            Text("Mode").foregroundStyle(Theme.textDim).frame(width: lw, alignment: .leading)
            Picker("", selection: Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })) {
                ForEach(modes) { Text(tr($0.displayName)).tag($0) }
            }.labelsHidden().frame(minWidth: 70, maxWidth: 130)
        }
    }

    private func dim(_ on: Bool) -> Double { on ? 1 : 0.45 }

    @ViewBuilder
    private func content(_ sec: BrushSettingsSection) -> some View {
        switch sec {
        case .tipShape:
            VStack(alignment: .leading, spacing: 6) {
                TipPickerGrid(tipID: $settings.tipID)
                ValueSlider(label: "Size", value: $settings.size, range: 1...1000, unit: " px", labelWidth: lw)
                HStack {
                    Toggle2(label: "Flip X", on: $settings.dynamics.flipX)
                    Toggle2(label: "Flip Y", on: $settings.dynamics.flipY)
                }
                WrappingHStack {
                    Text("Angle").foregroundStyle(Theme.textDim).frame(width: lw, alignment: .leading)
                    AngleDial(angle: $settings.angle).frame(width: 26, height: 26)
                    NumberField(label: "", value: $settings.angle, width: 40)
                    Text("°").foregroundStyle(Theme.textFaint)
                }
                ValueSlider(label: "Roundness", value: Binding(get: { settings.roundness * 100 }, set: { settings.roundness = max(0.01, $0 / 100) }), range: 1...100, unit: "%", labelWidth: lw)
                pct("Hardness", \.hardness).opacity(settings.tipID == "round" ? 1 : 0.45)
                ValueSlider(label: "Spacing", value: Binding(get: { settings.spacing * 100 }, set: { settings.spacing = max(0.01, $0 / 100) }), range: 1...1000, unit: "%", labelWidth: lw)
            }
        case .shape:
            VStack(alignment: .leading, spacing: 6) {
                pct("Size Jitter", \.sizeJitter)
                control(\.dynamics.sizeControl, BrushControl.shapeControls)
                pct("Min Diameter", \.dynamics.minDiameter)
                pct("Tilt Scale", \.dynamics.tiltScale, 0...200).opacity(settings.dynamics.sizeControl.source == .tilt ? 1 : 0.45)
                Divider()
                pct("Angle Jitter", \.dynamics.angleJitter)
                control(\.dynamics.angleControl, BrushControl.angleControls)
                Divider()
                pct("Round. Jitter", \.dynamics.roundnessJitter)
                control(\.dynamics.roundnessControl, BrushControl.shapeControls)
                pct("Min Roundness", \.dynamics.minRoundness, 1...100)
                WrappingHStack {
                    Toggle2(label: "Flip X Jitter", on: $settings.dynamics.flipXJitter)
                    Toggle2(label: "Flip Y Jitter", on: $settings.dynamics.flipYJitter)
                }
                Toggle2(label: "Brush Projection", on: $settings.dynamics.brushProjection)
            }.opacity(dim(settings.dynamics.shapeEnabled))
        case .scattering:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    pct("Scatter", \.scatter, 0...1000)
                }
                Toggle2(label: "Both Axes", on: $settings.dynamics.scatterBothAxes)
                control(\.dynamics.scatterControl, BrushControl.shapeControls)
                ValueSlider(label: "Count", value: $settings.dynamics.count, range: 1...16, step: 1, labelWidth: lw)
                pct("Count Jitter", \.dynamics.countJitter)
                control(\.dynamics.countControl, BrushControl.shapeControls)
            }.opacity(dim(settings.dynamics.scatterEnabled))
        case .texture:
            VStack(alignment: .leading, spacing: 6) {
                WrappingHStack {
                    Text("Pattern").foregroundStyle(Theme.textDim).frame(width: lw, alignment: .leading)
                    PatternPicker(patternID: $settings.dynamics.texturePatternID)
                    Toggle2(label: "Invert", on: $settings.dynamics.textureInvert)
                }
                pct("Scale", \.dynamics.textureScale, 1...1000)
                ValueSlider(label: "Brightness", value: $settings.dynamics.textureBrightness, range: -150...150, labelWidth: lw)
                ValueSlider(label: "Contrast", value: $settings.dynamics.textureContrast, range: -50...100, labelWidth: lw)
                Toggle2(label: "Texture Each Tip", on: $settings.dynamics.textureEachTip)
                modePicker(\.dynamics.textureMode, BrushMaskMode.textureModes)
                pct("Depth", \.dynamics.textureDepth)
                Group {
                    pct("Minimum Depth", \.dynamics.textureMinDepth)
                    pct("Depth Jitter", \.dynamics.textureDepthJitter)
                    control(\.dynamics.textureDepthControl, BrushControl.shapeControls)
                }.opacity(settings.dynamics.textureEachTip ? 1 : 0.45).disabled(!settings.dynamics.textureEachTip)
            }.opacity(dim(settings.dynamics.textureEnabled))
        case .dual:
            VStack(alignment: .leading, spacing: 6) {
                modePicker(\.dynamics.dualMode, BrushMaskMode.dualModes)
                TipPickerGrid(tipID: $settings.dynamics.dualTipID)
                ValueSlider(label: "Size", value: $settings.dynamics.dualSize, range: 1...1000, unit: " px", labelWidth: lw)
                pct("Hardness", \.dynamics.dualHardness).opacity(settings.dynamics.dualTipID == "round" ? 1 : 0.45)
                pct("Spacing", \.dynamics.dualSpacing, 1...1000)
                pct("Scatter", \.dynamics.dualScatter, 0...1000)
                Toggle2(label: "Both Axes", on: $settings.dynamics.dualBothAxes)
                ValueSlider(label: "Count", value: $settings.dynamics.dualCount, range: 1...16, step: 1, labelWidth: lw)
                Toggle2(label: "Flip", on: $settings.dynamics.dualFlip)
            }.opacity(dim(settings.dynamics.dualEnabled))
        case .color:
            VStack(alignment: .leading, spacing: 6) {
                Toggle2(label: "Apply Per Tip", on: $settings.dynamics.colorPerTip)
                pct("Fg/Bg Jitter", \.dynamics.fgBgJitter)
                control(\.dynamics.fgBgControl, BrushControl.transferControls)
                pct("Hue Jitter", \.dynamics.hueJitter)
                pct("Saturation Jit.", \.dynamics.saturationJitter)
                pct("Brightness Jit.", \.dynamics.brightnessJitter)
                control(\.dynamics.colorJitterControl, BrushControl.transferControls)   // scales hue / saturation / brightness jitter
                pct("Purity", \.dynamics.purity, -100...100)
            }.opacity(dim(settings.dynamics.colorEnabled))
        case .transfer:
            VStack(alignment: .leading, spacing: 6) {
                pct("Opacity Jitter", \.opacityJitter)
                control(\.dynamics.opacityControl, BrushControl.transferControls)
                pct("Minimum", \.dynamics.minOpacity)
                Divider()
                pct("Flow Jitter", \.dynamics.flowJitter)
                control(\.dynamics.flowControl, BrushControl.transferControls)
                pct("Minimum", \.dynamics.minFlow)
            }.opacity(dim(settings.dynamics.transferEnabled))
        case .pose:
            VStack(alignment: .leading, spacing: 6) {
                ValueSlider(label: "Tilt X", value: Binding(get: { settings.dynamics.poseTiltX * 100 }, set: { settings.dynamics.poseTiltX = $0 / 100 }), range: -100...100, unit: "%", labelWidth: lw)
                ValueSlider(label: "Tilt Y", value: Binding(get: { settings.dynamics.poseTiltY * 100 }, set: { settings.dynamics.poseTiltY = $0 / 100 }), range: -100...100, unit: "%", labelWidth: lw)
                Toggle2(label: "Override Tilt", on: $settings.dynamics.poseOverrideTilt)
                ValueSlider(label: "Rotation", value: $settings.dynamics.poseRotation, range: 0...360, unit: "°", labelWidth: lw)
                Toggle2(label: "Override Rotation", on: $settings.dynamics.poseOverrideRotation)
                pct("Pressure", \.dynamics.posePressure)
                Toggle2(label: "Override Pressure", on: $settings.dynamics.poseOverridePressure)
                Text("Stylus values used when the input device doesn't report them (a mouse), or always when overridden.")
                    .foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }.opacity(dim(settings.dynamics.poseEnabled))
        case .protectTexture:
            note("Keeps the current texture (pattern, scale, depth, mode) when another brush preset is chosen.", on: $settings.dynamics.protectTexture)
        case .noise:
            note("Adds grain to the soft edges of the stroke.", on: $settings.dynamics.noise)
        case .wetEdges:
            note("Paint collects at the stroke edges, the interior stays lighter (watercolor effect).", on: $settings.dynamics.wetEdges)
        case .buildUp:
            note("Airbrush: paint keeps building up while the mouse button is held.", on: $settings.airbrush)
        case .smoothing:
            VStack(alignment: .leading, spacing: 6) {
                pct("Smoothing", \.smoothing, 0...95)
                Text("Smooths the stroke path to reduce jitter.").foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func note(_ text: String, on: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle2(label: "Enabled", on: on)
            Text(tr(text)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}
