import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageCratCore

/// The particle editor dialog (non-dimming, floats over the canvas; the preview is live on the canvas).
struct ParticleEditorDialog: View {
    var body: some View {
        if let ed = ParticleEditor.current {
            ParticleEditorPanel(editor: ed, st: ed.state)
        } else {
            Text("No particle session").padding(20)
        }
    }
}

private let pLabelWidth: CGFloat = 96

/// Slider row bound to a Double. Wide ranges use a power curve so small values stay easy to set
/// (symmetric around zero for ranges that include negative values).
private struct PSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = ""
    var format = "%.0f"
    var power: Double = 1

    /// Typed, uncommitted text and the text just committed (see `ValueSlider`).
    @State private var draft: String?
    @State private var committed: String?
    @State private var fieldID = UUID()
    @FocusState private var focused: Bool

    private var symmetric: Bool { range.lowerBound < 0 && range.upperBound > 0 }

    private func position(_ v: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        let c = min(max(v, lo), hi)
        if symmetric {
            let m = max(-lo, hi)
            let p = pow(abs(c) / m, 1 / power)
            return 0.5 + 0.5 * (c < 0 ? -p : p)
        }
        return pow((c - lo) / (hi - lo), 1 / power)
    }

    private func valueAt(_ p: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        if symmetric {
            let m = max(-lo, hi)
            let q = (p - 0.5) * 2
            return min(max((q < 0 ? -1 : 1) * pow(abs(q), power) * m, lo), hi)
        }
        return lo + (hi - lo) * pow(p, power)
    }

    var body: some View {
        let _ = draft == nil ? () : FieldEdits.refresh(fieldID, commit: commit, discard: { draft = nil })
        HStack(spacing: 6) {
            Text(label).font(Theme.font).foregroundStyle(Theme.textDim).frame(width: pLabelWidth, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { position(value) }, set: { value = valueAt($0) }), in: 0...1).controlSize(.mini)
            HStack(spacing: 1) {
                TextField("", text: Binding(get: { draft ?? String(format: format, value) }, set: { t in
                    guard draft != nil || (t != String(format: format, value) && t != committed) else { return }
                    committed = nil
                    draft = t
                    FieldEdits.edited(fieldID, commit: commit, discard: { draft = nil })
                }))
                    .textFieldStyle(.plain).font(Theme.mono).multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit { commit() }
                if !unit.isEmpty { Text(unit).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(width: 62)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    /// Typed values may exceed the slider range (only the sign / lower bound is enforced).
    private func commit() {
        guard let t = draft else { return }
        draft = nil
        committed = t
        FieldEdits.ended(fieldID)
        if let v = Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), v.isFinite {
            value = range.lowerBound >= 0 ? max(range.lowerBound, v) : v
        }
    }
}

private struct PRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.font).foregroundStyle(Theme.textDim).frame(width: pLabelWidth, alignment: .leading).lineLimit(1)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct PSection<Content: View>: View {
    let title: String
    @Binding var open: Set<String>
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title, expanded: Binding(get: { open.contains(title) }, set: { if $0 { open.insert(title) } else { open.remove(title) } }))
            if open.contains(title) {
                VStack(alignment: .leading, spacing: 5) { content }.padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
        .overlay(Rectangle().fill(Theme.divider.opacity(0.5)).frame(height: 1), alignment: .top)
    }
}

private struct PEnumPicker<T: PTolerantEnum & Identifiable & Hashable>: View {
    let label: String
    @Binding var value: T
    let name: (T) -> String
    var body: some View {
        PRow(label: label) {
            Picker("", selection: $value) {
                ForEach(Array(T.allCases), id: \.self) { Text(name($0)).tag($0) }
            }.labelsHidden().frame(maxWidth: 210)
        }
    }
}

struct ParticleEditorPanel: View {
    let editor: ParticleEditor
    @Bindable var st: ParticleEditorState
    @State private var open: Set<String>
    @State private var showPresets = false
    /// Fixed height of the scrolling part (nil = fit the screen); snapshots pass a tall value to show every section.
    let contentHeight: CGFloat?

    static let allSections: Set<String> = ["Emitter", "Emission", "Velocity", "Forces", "Sprite", "Colour & Opacity", "Trails", "Depth", "Sub-emitter", "Output"]

    init(editor: ParticleEditor, st: ParticleEditorState, open: Set<String> = ["Emitter", "Emission", "Output"], contentHeight: CGFloat? = nil) {
        self.editor = editor
        self.st = st
        _open = State(initialValue: open)
        self.contentHeight = contentHeight
    }

    private var sys: Binding<ParticleSystemSettings> { Binding(get: { st.system }, set: { st.system = $0 }) }
    private var effect: Binding<ParticleEffect> { $st.effect }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ParticleSystemsList(st: st)
                    timeRow
                    PEmitterSection(st: st, s: sys, open: $open)
                    PEmissionSection(s: sys, isSub: st.editSub, open: $open)
                    PMotionSection(s: sys, isSub: st.editSub, open: $open)
                    PForcesSection(s: sys, open: $open)
                    PSpriteSection(editor: editor, s: sys, open: $open)
                    PLookSection(s: sys, open: $open)
                    PTrailDepthSection(st: st, s: sys, open: $open)
                    POutputSection(editor: editor, st: st, open: $open)
                }
                .padding(.trailing, 10)
            }
            .frame(height: contentHeight ?? min(560, max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 330)))
            footer
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .frame(width: 400)
        .background(ParticleCardProbe())
        .onChange(of: st.effect) { _, _ in editor.schedulePreview() }
        .onDisappear { if !editor.isClosed { editor.cancel() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Particles").font(.system(size: 13, weight: .semibold))
            TextField("Name", text: effect.name).textFieldStyle(.plain).font(Theme.font)
                .padding(.horizontal, 5).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
            Button { showPresets.toggle() } label: { Label("Presets", systemImage: "square.grid.2x2") }
                .buttonStyle(PanelButtonStyle())
                .popover(isPresented: $showPresets, arrowEdge: .bottom) { ParticlePresetPicker(current: st.presetID) { showPresets = false } }
        }
    }

    private var timeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button { editor.togglePlay() } label: { Image(systemName: st.playing ? "pause.fill" : "play.fill") }.buttonStyle(.plain).help("Play the simulation in the preview")
                ValueSlider(label: "Moment", value: effect.time, range: 0...max(0.5, st.effect.duration), unit: "s", format: "%.2f", labelWidth: 50)
            }
            HStack(spacing: 6) {
                NumberField(label: "Length", value: effect.duration, width: 44, format: "%.1f")
                Text("s").foregroundStyle(Theme.textFaint)
                Spacer()
                NumberField(label: "Seed", value: Binding(get: { Double(st.effect.seed) }, set: { st.effect.seed = Int($0) }), width: 60)
                Button { st.effect.seed = Int.random(in: 1...999_999) } label: { Label("Randomize", systemImage: "dice") }.buttonStyle(PanelButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                let ms = st.simMS + st.renderMS
                Circle().fill(ms < 60 ? Color.green : ms < 220 ? Color.yellow : Color.red).frame(width: 8, height: 8)
                Text("\(st.particles.formatted()) particles · \(st.instances.formatted()) sprites · \(String(format: "%.0f", ms)) ms")
                    .font(Theme.mono).foregroundStyle(Theme.textDim)
                Spacer()
                if !st.status.isEmpty { Text(st.status).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1) }
            }
            HStack {
                Button("Save Preset…") { ParticleActions.savePreset(st.effect) }.buttonStyle(PanelButtonStyle())
                Spacer()
                Button("Cancel") { editor.cancel() }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button(st.isReedit ? "Update" : "OK") { FieldEdits.commit(); editor.apply() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Systems list ("multiple systems")

struct ParticleSystemsList: View {
    @Bindable var st: ParticleEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Caption("Systems")
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add a system")
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(.plain).help("Duplicate the selected system")
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).help("Move up (drawn later)")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.plain).help("Move down (drawn earlier)")
                Button { remove() } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete the selected system").disabled(st.effect.systems.count <= 1)
            }
            // topmost system first, like the Layers panel
            ForEach(Array(st.effect.systems.enumerated()).reversed(), id: \.element.id) { i, s in
                row(i, s, sub: false)
                if let c = s.sub.first { row(i, c, sub: true) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG.opacity(0.6)))
    }

    @ViewBuilder private func row(_ i: Int, _ s: ParticleSystemSettings, sub: Bool) -> some View {
        let selected = st.selected == i && st.editSub == sub
        HStack(spacing: 6) {
            if sub { Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(Theme.textFaint).padding(.leading, 14) }
            else {
                Toggle("", isOn: Binding(get: { st.effect.systems[safe: i]?.enabled ?? true }, set: { v in if st.effect.systems.indices.contains(i) { st.effect.systems[i].enabled = v } }))
                    .toggleStyle(.checkbox).labelsHidden()
            }
            Text(s.name + (sub ? " (on death)" : "")).font(Theme.font).foregroundStyle(selected ? Color.white : Theme.text).lineLimit(1)
            Spacer()
            if !sub { Text(s.blend == .additive ? "Add" : s.blend == .multiply ? "Mul" : "Normal").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Theme.accent.opacity(0.7) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { st.selected = i; st.editSub = sub }
    }

    private func add() {
        var s = ParticleSystemSettings()
        s.name = "System \(st.effect.systems.count + 1)"
        s.rate = 80; s.gradient = ColorGradient.twoColor(.white, .white, name: "Over life")
        st.effect.systems.append(s)
        st.selected = st.effect.systems.count - 1; st.editSub = false
    }
    private func duplicate() {
        guard st.effect.systems.indices.contains(st.selected) else { return }
        var s = st.effect.systems[st.selected]
        s.id = UUID(); s.name += " copy"
        st.effect.systems.insert(s, at: st.selected + 1)
        st.selected += 1; st.editSub = false
    }
    private func remove() {
        guard st.effect.systems.count > 1, st.effect.systems.indices.contains(st.selected) else { return }
        st.effect.systems.remove(at: st.selected)
        st.selected = min(st.selected, st.effect.systems.count - 1); st.editSub = false
    }
    private func move(_ d: Int) {
        // the list shows the top system first: "up" means later in the array
        let i = st.selected, j = i - d
        guard st.effect.systems.indices.contains(i), st.effect.systems.indices.contains(j) else { return }
        st.effect.systems.swapAt(i, j)
        st.selected = j
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Sections

private struct PEmitterSection: View {
    @Bindable var st: ParticleEditorState
    @Binding var s: ParticleSystemSettings
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Emitter", open: $open) {
            PRow(label: "Name") {
                TextField("", text: $s.name).textFieldStyle(.plain).font(Theme.font)
                    .padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)).frame(maxWidth: 210)
            }
            if st.editSub {
                Text("Sub-emitter particles start where their parent dies.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            } else {
                PEnumPicker(label: "Shape", value: $s.shape) { $0.displayName }
                PEnumPicker(label: "Blending", value: $s.blend) { $0.displayName }
                if !(s.shape.usesMap && s.shape != .text) {
                    PSlider(label: "Position X", value: Binding(get: { s.pos.x * 100 }, set: { s.pos.x = $0 / 100 }), range: -20...120, unit: "%")
                    PSlider(label: "Position Y", value: Binding(get: { s.pos.y * 100 }, set: { s.pos.y = $0 / 100 }), range: -20...120, unit: "%")
                }
                if [.line, .circle, .ring, .rectangle, .frame, .grid, .spiral, .text].contains(s.shape) {
                    PSlider(label: "Width", value: Binding(get: { s.size.width * 100 }, set: { s.size.width = $0 / 100 }), range: 0...250, unit: "%")
                    if s.shape != .line {
                        PSlider(label: "Height", value: Binding(get: { s.size.height * 100 }, set: { s.size.height = $0 / 100 }), range: 0...250, unit: "%")
                    }
                    PRow(label: "Rotation") {
                        AngleDial(angle: $s.emitterRotation)
                        NumberField(label: "", value: $s.emitterRotation, width: 44)
                        Text("°").foregroundStyle(Theme.textFaint)
                    }
                }
                shapeExtras
                PSlider(label: "Clumping", value: $s.densityNoise, range: 0...1, format: "%.2f")
                if s.densityNoise > 0 { PSlider(label: "Clump size", value: $s.densityNoiseScale, range: 40...1200, power: 2) }
                Text("Drag the handles on the canvas: ● position, ■ size / rotation, → direction and speed (⌥ direction only).")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var shapeExtras: some View {
        switch s.shape {
        case .spiral:
            PSlider(label: "Arms", value: $s.arms, range: 1...8)
            PSlider(label: "Twist", value: $s.twist, range: -6...6, format: "%.1f")
        case .grid:
            PSlider(label: "Jitter", value: $s.gridJitter, range: 0...1, format: "%.2f")
        case .text:
            PRow(label: "Text") {
                TextField("", text: $s.text).textFieldStyle(.plain).font(Theme.font)
                    .padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)).frame(maxWidth: 210)
            }
            PRow(label: "Font") {
                TextField("", text: $s.textFont).textFieldStyle(.plain).font(Theme.font)
                    .padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)).frame(maxWidth: 210)
            }
            PRow(label: "") { Toggle2(label: "Outlines only", on: $s.outlineOnly) }
        case .path:
            PRow(label: "Path") {
                Toggle("Draw on canvas", isOn: $st.drawPath).toggleStyle(.checkbox).font(Theme.font)
                Button("Use Active Path") { ParticleActions.useActivePath(st) }.buttonStyle(PanelButtonStyle())
            }
            PRow(label: "") {
                Toggle2(label: "Closed", on: $s.pathClosed)
                Text("\(s.pathPoints.count) points").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        case .selectionArea, .selectionOutline:
            Text(ParticleEditor.current?.ctx.selection == nil ? "No selection — the emitter falls back to its rectangle." : "Emits from the current selection.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        case .layerAlpha, .layerEdges:
            Text(ParticleEditor.current?.ctx.layerAlpha == nil ? "The source layer is empty — the emitter falls back to its rectangle." : "Emits from the layer that was active when the editor opened (pixels, text or shape).")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        case .brightness:
            PRow(label: "") { Toggle2(label: "Edges only", on: $s.outlineOnly) }
            Text("Brighter areas of the image emit more particles.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        default: EmptyView()
        }
    }
}

private struct PEmissionSection: View {
    @Binding var s: ParticleSystemSettings
    let isSub: Bool
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Emission", open: $open) {
            if isSub {
                PSlider(label: "Per parent", value: $s.count, range: 1...600, power: 2)
                PSlider(label: "Spread over", value: $s.burstSpread, range: 0...2, unit: "s", format: "%.2f", power: 2)
            } else {
                PEnumPicker(label: "Mode", value: $s.emission) { $0.displayName }
                if s.emission == .rate {
                    PSlider(label: "Rate", value: $s.rate, range: 0.2...20000, unit: "/s", power: 3)
                    PSlider(label: "Emit for", value: $s.emitDuration, range: 0...20, unit: "s", format: "%.1f", power: 2)
                } else {
                    PSlider(label: "Count", value: $s.count, range: 1...300000, power: 4)
                    PSlider(label: "Repeat every", value: $s.burstInterval, range: 0...5, unit: "s", format: "%.2f", power: 2)
                    PSlider(label: "Spread over", value: $s.burstSpread, range: 0...3, unit: "s", format: "%.2f", power: 2)
                }
                PSlider(label: "Start time", value: $s.startTime, range: 0...10, unit: "s", format: "%.2f", power: 2)
                PRow(label: "") { Toggle2(label: "Pre-warm (already running at time 0)", on: $s.prewarm) }
                PSlider(label: "Sweep", value: $s.sweep, range: 0...10, unit: "s", format: "%.1f", power: 2)
                if s.sweep > 0 {
                    PRow(label: "Blown towards") { AngleDial(angle: $s.sweepAngle); NumberField(label: "", value: $s.sweepAngle, width: 44); Text("°").foregroundStyle(Theme.textFaint) }
                    PSlider(label: "Ragged edge", value: $s.sweepNoise, range: 0...1, format: "%.2f")
                }
            }
            PSlider(label: "Life min", value: $s.lifeMin, range: 0.05...30, unit: "s", format: "%.2f", power: 2)
            PSlider(label: "Life max", value: $s.lifeMax, range: 0.05...30, unit: "s", format: "%.2f", power: 2)
            if !isSub { PRow(label: "") { Toggle2(label: "Immortal (over-life curves repeat)", on: $s.immortal) } }
        }
    }
}

private struct PMotionSection: View {
    @Binding var s: ParticleSystemSettings
    let isSub: Bool
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Velocity", open: $open) {
            PRow(label: "Direction") { AngleDial(angle: $s.direction); NumberField(label: "", value: $s.direction, width: 44); Text("°").foregroundStyle(Theme.textFaint) }
            PSlider(label: "Spread", value: $s.spread, range: 0...360, unit: "°")
            PSlider(label: "Speed min", value: $s.speedMin, range: 0...3000, power: 2)
            PSlider(label: "Speed max", value: $s.speedMax, range: 0...3000, power: 2)
            PSlider(label: "Radial", value: $s.radialSpeed, range: -2000...2000, power: 2)
            PSlider(label: "Tangential", value: $s.tangentialSpeed, range: -2000...2000, power: 2)
            if !isSub { PSlider(label: "Along normal", value: $s.normalSpeed, range: -1500...1500, power: 2) }
            if isSub { PSlider(label: "Inherit parent", value: $s.inheritVelocity, range: 0...1, format: "%.2f") }
        }
    }
}

private struct PForcesSection: View {
    @Binding var s: ParticleSystemSettings
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Forces", open: $open) {
            PSlider(label: "Gravity", value: $s.gravity, range: -2500...2500, power: 2)
            PSlider(label: "Wind", value: $s.wind, range: -2500...2500, power: 2)
            PSlider(label: "Gusts", value: $s.gust, range: 0...2, format: "%.2f")
            PSlider(label: "Drag", value: $s.drag, range: 0...8, format: "%.2f")
            PSlider(label: "Turbulence", value: $s.turbulence, range: 0...800, power: 2)
            PSlider(label: "Noise force", value: $s.noiseForce, range: 0...80000, power: 3)
            PSlider(label: "Noise scale", value: $s.turbulenceScale, range: 4...1200, power: 2)
            PSlider(label: "Noise speed", value: $s.turbulenceSpeed, range: 0...8, format: "%.2f")
            PSlider(label: "Vortex", value: $s.vortex, range: -720...720, unit: "°/s", power: 2)
            PSlider(label: "Vortex pull", value: $s.vortexPull, range: -400...400, power: 2)
            if s.vortex != 0 || s.vortexPull != 0 { PSlider(label: "Vortex radius", value: $s.vortexRadius, range: 20...1500) }
            ForEach(Array(s.attractors.enumerated()), id: \.element.id) { i, _ in
                HStack(spacing: 4) {
                    ValueSlider(label: "Attractor \(i + 1)", value: Binding(get: { s.attractors[safe: i]?.strength ?? 0 }, set: { if s.attractors.indices.contains(i) { s.attractors[i].strength = $0 } }),
                                range: -4000...4000, labelWidth: pLabelWidth)
                    Button { if s.attractors.indices.contains(i) { s.attractors.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
                ValueSlider(label: "   radius", value: Binding(get: { s.attractors[safe: i]?.radius ?? 0 }, set: { if s.attractors.indices.contains(i) { s.attractors[i].radius = $0 } }),
                            range: 10...1500, labelWidth: pLabelWidth)
            }
            PRow(label: "") {
                Button("Add Attractor") { s.attractors.append(PAttractor()) }.buttonStyle(PanelButtonStyle())
                Text("negative strength repels").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            PSlider(label: "Follow path", value: $s.followPath, range: 0...1, format: "%.2f")
            if s.followPath > 0 { PSlider(label: "Path speed", value: $s.followSpeed, range: 0...2000, power: 2) }
            Caption("Collisions")
            PRow(label: "") { Toggle2(label: "Bounce off canvas edges", on: $s.bounceEdges) }
            PRow(label: "") { Toggle2(label: "Floor", on: $s.floorEnabled) }
            if s.floorEnabled { PSlider(label: "Floor height", value: Binding(get: { s.floorY * 100 }, set: { s.floorY = $0 / 100 }), range: 0...120, unit: "%") }
            PRow(label: "") { Toggle2(label: "Collide with selection / layer mask", on: $s.collideMask) }
            PRow(label: "") { Toggle2(label: "Confine to the emitter shape", on: $s.confine) }
            if s.bounceEdges || s.floorEnabled || s.collideMask || s.confine {
                PSlider(label: "Restitution", value: $s.restitution, range: 0...1, format: "%.2f")
                PSlider(label: "Friction", value: $s.friction, range: 0...1, format: "%.2f")
                PRow(label: "") { Toggle2(label: "Die on impact (triggers the sub-emitter)", on: $s.dieOnCollision) }
            }
        }
    }
}

private struct PSpriteSection: View {
    let editor: ParticleEditor
    @Binding var s: ParticleSystemSettings
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Sprite", open: $open) {
            PEnumPicker(label: "Sprite", value: $s.sprite) { $0.displayName }
            switch s.sprite {
            case .star: PSlider(label: "Points", value: $s.spritePoints, range: 3...16)
            case .sparkle: PSlider(label: "Rays", value: $s.spritePoints, range: 4...12)
            case .bokeh:
                PSlider(label: "Blades", value: $s.spritePoints, range: 0...9)
                PSlider(label: "Softness", value: $s.spriteSoftness, range: 0...1, format: "%.2f")
            case .softDisc: PSlider(label: "Softness", value: $s.spriteSoftness, range: 0...1, format: "%.2f")
            case .glyph:
                PRow(label: "Characters") {
                    TextField("", text: $s.spriteText).textFieldStyle(.plain).font(Theme.font)
                        .padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)).frame(maxWidth: 210)
                }
                PRow(label: "Font") {
                    TextField("", text: $s.spriteFont).textFieldStyle(.plain).font(Theme.font)
                        .padding(.horizontal, 4).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)).frame(maxWidth: 210)
                }
                Text("Each particle picks one of the characters (emoji work too).").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            case .shape:
                PRow(label: "Shape") {
                    Picker("", selection: $s.spriteShape) {
                        ForEach(ShapeLibrary.all) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 210)
                }
            case .image:
                PRow(label: "Image") {
                    Button("From Active Layer") { if let p = ParticleSources.spriteFromActiveLayer(editor.doc) { s.spriteImagePNG = p } else { Beep.play() } }.buttonStyle(PanelButtonStyle())
                    Button("From Brush Tip") { if let p = ParticleSources.spriteFromBrushTip() { s.spriteImagePNG = p } else { Beep.play() } }.buttonStyle(PanelButtonStyle())
                }
                if s.spriteImagePNG == nil { Text("No image yet — a soft disc is used.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            default: EmptyView()
            }
            PSlider(label: "Aspect", value: $s.spriteAspect, range: 0.02...3, format: "%.2f")
            PSlider(label: "Size min", value: $s.sizeMin, range: 0.5...1500, format: "%.1f", power: 3)
            PSlider(label: "Size max", value: $s.sizeMax, range: 0.5...3500, format: "%.1f", power: 3)
            PSlider(label: "Small bias", value: $s.sizeBias, range: 0.3...5, format: "%.1f")
            PSlider(label: "By distance", value: $s.sizeByDistance, range: -1...1, format: "%.2f")
            PCurveRow(label: "Size over life", curve: $s.sizeCurve)
            PRow(label: "Rotation") { AngleDial(angle: $s.rotation); NumberField(label: "", value: $s.rotation, width: 44); Text("°").foregroundStyle(Theme.textFaint) }
            PSlider(label: "Random rot.", value: $s.rotationRandom, range: 0...180, unit: "°")
            PSlider(label: "Spin", value: $s.spin, range: -720...720, unit: "°/s", power: 2)
            PSlider(label: "Random spin", value: $s.spinRandom, range: 0...720, unit: "°/s", power: 2)
            PSlider(label: "3D tumble", value: $s.tumble, range: 0...6, format: "%.2f")
            PRow(label: "") { Toggle2(label: "Align to velocity", on: $s.alignToVelocity) }
        }
    }
}

private struct PCurveRow: View {
    let label: String
    @Binding var curve: CurvePoints
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(Theme.font).foregroundStyle(Theme.textDim)
                Spacer()
                Menu("Shape") {
                    Button("Constant") { curve = .flat }
                    Button("Fade out") { curve = .fadeOut }
                    Button("Fade in / out") { curve = .fadeInOut }
                    Button("Quick in, slow out") { curve = .quickInSlowOut }
                    Button("Grow") { curve = .grow }
                    Button("Shrink") { curve = .shrink }
                }.menuStyle(.borderlessButton).frame(width: 70)
            }
            CurveEditor(curve: $curve, hist: nil, channel: 0, color: Color.white, onCommit: {})
                .frame(height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

private struct PLookSection: View {
    @Binding var s: ParticleSystemSettings
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Colour & Opacity", open: $open) {
            PEnumPicker(label: "Base colour", value: $s.colorBase) { $0.displayName }
            if s.colorBase == .palette {
                Caption("Palette (each particle picks one)")
                GradientStopsEditor(gradient: $s.palette)
            }
            Caption("Colour over life")
            GradientStopsEditor(gradient: $s.gradient)
            PSlider(label: "Hue variation", value: $s.hueVariation, range: 0...1, format: "%.2f")
            PSlider(label: "Brightness var.", value: $s.brightnessVariation, range: 0...1, format: "%.2f")
            PSlider(label: "Opacity", value: Binding(get: { s.opacity * 100 }, set: { s.opacity = $0 / 100 }), range: 0...100, unit: "%")
            PSlider(label: "Random opacity", value: $s.opacityRandom, range: 0...1, format: "%.2f")
            PCurveRow(label: "Opacity over life", curve: $s.opacityCurve)
            PSlider(label: "Twinkle", value: $s.twinkle, range: 0...1, format: "%.2f")
            if s.twinkle > 0 { PSlider(label: "Twinkle speed", value: $s.twinkleSpeed, range: 0.1...30, unit: "Hz", format: "%.1f") }
        }
    }
}

private struct PTrailDepthSection: View {
    @Bindable var st: ParticleEditorState
    @Binding var s: ParticleSystemSettings
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Trails", open: $open) {
            PEnumPicker(label: "Trail", value: $s.trail) { $0.displayName }
            if s.trail != .none {
                PSlider(label: "Length", value: $s.trailLength, range: 0.005...3, unit: "s", format: "%.3f", power: 2)
                PSlider(label: "Width", value: $s.trailWidth, range: 0.05...3, format: "%.2f")
                if s.trail == .ribbon || s.trail == .echo {
                    PSlider(label: "Segments", value: $s.trailSegments, range: 2...64)
                    PRow(label: "") { Toggle2(label: "Colour gradient runs along the trail", on: $s.trailGradient) }
                }
            }
            PSlider(label: "Snap to grid", value: $s.snapGrid, range: 0...120, power: 2)
        }
        PSection(title: "Depth", open: $open) {
            PSlider(label: "Depth", value: $s.depth, range: 0...1, format: "%.2f")
            PSlider(label: "Focus", value: $s.focus, range: 0...1, format: "%.2f")
            PSlider(label: "DOF blur", value: $s.dofBlur, range: 0...2, format: "%.2f")
            PSlider(label: "Atmosphere", value: $s.atmosphere, range: 0...1, format: "%.2f")
            Text("Near particles are larger, faster and (with DOF blur) out of focus; Atmosphere fades the far ones.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        if !st.editSub {
            PSection(title: "Sub-emitter", open: $open) {
                let has = !(st.effect.systems[safe: st.selected]?.sub.isEmpty ?? true)
                PRow(label: "") {
                    Toggle("Spawn particles when one dies", isOn: Binding(get: { has }, set: { on in
                        guard st.effect.systems.indices.contains(st.selected) else { return }
                        if on { st.effect.systems[st.selected].sub = [ParticleActions.defaultSubEmitter()] } else { st.effect.systems[st.selected].sub = [] }
                    })).toggleStyle(.checkbox).font(Theme.font)
                }
                if has {
                    PRow(label: "") { Button("Edit Sub-emitter") { st.editSub = true }.buttonStyle(PanelButtonStyle()) }
                }
            }
        }
    }
}

private struct POutputSection: View {
    let editor: ParticleEditor
    @Bindable var st: ParticleEditorState
    @Binding var open: Set<String>

    var body: some View {
        PSection(title: "Output", open: $open) {
            if st.isReedit {
                Text("Editing a particle Smart Object — Update re-renders it in place.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            } else {
                PEnumPicker(label: "Create", value: $st.effect.output) { $0.displayName }
            }
            PRow(label: "Layer blend") {
                Picker("", selection: $st.effect.layerBlend) {
                    Text("Automatic").tag(BlendMode?.none)
                    ForEach([BlendMode.normal, .screen, .linearDodge, .lighten, .overlay, .softLight], id: \.self) { Text($0.displayName).tag(BlendMode?.some($0)) }
                }.labelsHidden().frame(maxWidth: 210)
            }
            PEnumPicker(label: "Quality", value: $st.effect.quality) { $0.displayName }
            PRow(label: "") { Toggle2(label: "Clip to the selection", on: $st.effect.clipToSelection) }
            PRow(label: "") { Toggle2(label: "Place behind the main subject", on: $st.effect.behindSubject) }
            PRow(label: "") { Toggle2(label: "Depth-aware placement (needs the depth model)", on: $st.effect.depthAware) }
            if st.effect.systems.contains(where: { $0.sweep > 0 }) {
                PRow(label: "") { Toggle2(label: "Mask the dissolved part of the source layer", on: $st.effect.maskSourceLayer) }
            }
            Caption("Animate")
            HStack(spacing: 8) {
                NumberField(label: "Frames", value: $st.effect.frames, width: 40)
                NumberField(label: "fps", value: $st.effect.fps, width: 34)
                NumberField(label: "From", value: $st.effect.animStart, width: 38, format: "%.1f")
                Toggle2(label: "Loop", on: $st.effect.loop)
            }
            Text(st.effect.loop ? "Seamless loop: the last frame leads back into the first (lifetimes wrap around)." : "Frames start at “From” seconds and advance by 1 / fps.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("To Frame Animation") { editor.animate(.frames) }.buttonStyle(PanelButtonStyle())
                Button("To Video Timeline") { editor.animate(.timeline) }.buttonStyle(PanelButtonStyle())
            }
            Button("Export PNG Sequence…") { ParticleActions.exportSequence(editor) }.buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - Preset picker (thumbnails)

struct ParticlePresetPicker: View {
    let current: String?
    let done: () -> Void
    @Bindable var thumbs = ParticleThumbnails.shared
    @Bindable var user = ParticleUserPresets.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ParticlePresets.categories, id: \.self) { cat in
                    Caption(cat)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
                        ForEach(ParticlePresets.all.filter { $0.category == cat }) { p in
                            cell(p.name, image: thumbs.image(p.id), selected: p.id == current) { ParticleEditor.open(presetID: p.id); done() }
                        }
                    }
                }
                if !user.presets.isEmpty {
                    Caption("User presets")
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
                        ForEach(user.presets) { e in
                            cell(e.name, image: nil, selected: false) { if let fx = user.load(e.url) { ParticleEditor.open(fx) }; done() }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 456, height: 460)
    }

    private func cell(_ name: String, image: NSImage?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.08))
                    if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill) }
                    else { Image(systemName: "sparkles").foregroundStyle(Color(white: 0.4)) }
                }
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accent : Color(white: 0.3), lineWidth: selected ? 2 : 0.5))
                Text(name).font(Theme.fontSmall).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.center).frame(width: 98, height: 24, alignment: .top)
            }
        }.buttonStyle(.plain)
    }
}

// MARK: - Manage presets

struct ParticlePresetManager: View {
    @Bindable var user = ParticleUserPresets.shared
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Particle Presets").font(.system(size: 13, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if user.presets.isEmpty {
                        Text("No saved presets yet. Use “Save Preset…” in the particle editor.").font(Theme.font).foregroundStyle(Theme.textFaint).padding(8)
                    }
                    ForEach(user.presets) { e in
                        HStack {
                            Text(e.name).font(Theme.font).foregroundStyle(selected == e.id ? Color.white : Theme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(selected == e.id ? Theme.accent.opacity(0.7) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { selected = e.id }
                    }
                }
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            HStack(spacing: 6) {
                Button("Apply…") { if let e = entry, let fx = user.load(e.url) { AppModel.shared.dialog = nil; ParticleEditor.open(fx) } }.buttonStyle(PanelButtonStyle()).disabled(entry == nil || AppActions.doc == nil)
                Button("Rename…") { if let e = entry, let n = ParticleActions.askName("Rename Preset", initial: e.name) { user.rename(e, to: n) } }.buttonStyle(PanelButtonStyle()).disabled(entry == nil)
                Button("Delete") { if let e = entry { user.delete(e); selected = nil } }.buttonStyle(PanelButtonStyle()).disabled(entry == nil)
                Spacer()
            }
            HStack(spacing: 6) {
                Button("Import…") { ParticleActions.importPresets() }.buttonStyle(PanelButtonStyle())
                Button("Export…") { if let e = entry { ParticleActions.exportPreset(e) } }.buttonStyle(PanelButtonStyle()).disabled(entry == nil)
                Button("Show in Finder") { ParticleActions.revealPresets() }.buttonStyle(PanelButtonStyle())
                Spacer()
                Button("Done") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 420)
        .onAppear { user.reload() }
    }

    private var entry: ParticleUserPresets.Entry? { user.presets.first { $0.id == selected } }
}
