import SwiftUI
import ImageCratCore

/// The repeater's controls, shared by the Repeat… dialog and the Properties panel.
struct RepeaterControls: View {
    @Binding var s: RepeaterSettings
    var labelWidth: CGFloat = 84
    var onCommit: () -> Void = {}

    private func int(_ kp: WritableKeyPath<RepeaterSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(s[keyPath: kp]) }, set: { s[keyPath: kp] = Int($0.rounded()) })
    }
    private func pick<T: Hashable>(_ kp: WritableKeyPath<RepeaterSettings, T>) -> Binding<T> {
        Binding(get: { s[keyPath: kp] }, set: { s[keyPath: kp] = $0; onCommit() })
    }

    /// Shapes that make sense for a repeater (the arrange grid is replaced by the Grid mode).
    static let shapes: [ArrangeSettings.Shape] = ArrangeSettings.Shape.allCases.filter { $0 != .grid }

    var body: some View {
        Picker("", selection: pick(\.mode)) { ForEach(RepeaterSettings.Mode.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden()
        switch s.mode {
        case .grid:
            ValueSlider(label: "Columns", value: int(\.columns), range: 1...20, step: 1, labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Rows", value: int(\.rows), range: 1...20, step: 1, labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Column gap", value: $s.gapX, range: -200...400, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Row gap", value: $s.gapY, range: -200...400, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Brick offset", value: $s.stagger, range: 0...100, unit: "%", labelWidth: labelWidth, onCommit: onCommit)
        case .radial:
            ValueSlider(label: "Count", value: int(\.count), range: 1...72, step: 1, labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Radius", value: $s.radius, range: 0...2000, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Arc", value: $s.arc, range: 10...360, unit: "°", labelWidth: labelWidth, onCommit: onCommit)
            Toggle2(label: "Rotate instances", on: pick(\.rotateInstances))
        case .path:
            Picker("Shape", selection: pick(\.shape)) { ForEach(RepeaterControls.shapes) { Text($0.rawValue).tag($0.rawValue) } }
            if s.shape == ArrangeSettings.Shape.custom.rawValue {
                HStack { Text("Custom shape").foregroundStyle(Theme.textDim); ShapeLibraryPicker(id: pick(\.customID)) }
            }
            if s.shape == ArrangeSettings.Shape.path.rawValue {
                Text(s.captured == nil ? "Select a path in the Paths panel before choosing Repeat…" : "Uses the path that was active when the repeater was made.")
                    .font(Theme.fontSmall).foregroundStyle(s.captured == nil ? .orange : Theme.textFaint)
            } else {
                ValueSlider(label: "Width", value: $s.shapeWidth, range: 10...4000, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
                ValueSlider(label: "Height", value: $s.shapeHeight, range: 0...4000, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
                ValueSlider(label: "Rotate shape", value: $s.shapeRotation, range: -180...180, unit: "°", labelWidth: labelWidth, onCommit: onCommit)
            }
            switch ArrangeSettings.Shape(rawValue: s.shape) ?? .circle {
            case .polygon, .star:
                ValueSlider(label: "Sides", value: int(\.sides), range: 3...24, step: 1, labelWidth: labelWidth, onCommit: onCommit)
            case .arc: ValueSlider(label: "Arc angle", value: $s.arcAngle, range: 10...360, unit: "°", labelWidth: labelWidth, onCommit: onCommit)
            case .spiral: ValueSlider(label: "Turns", value: $s.turns, range: 0.5...8, format: "%.1f", labelWidth: labelWidth, onCommit: onCommit)
            case .wave: ValueSlider(label: "Waves", value: $s.waves, range: 0.5...8, format: "%.1f", labelWidth: labelWidth, onCommit: onCommit)
            default: EmptyView()
            }
            ValueSlider(label: "Count", value: int(\.count), range: 1...120, step: 1, labelWidth: labelWidth, onCommit: onCommit)
            Toggle2(label: "Follow the path", on: pick(\.followPath))
        case .mirror:
            Picker("Mirror", selection: pick(\.mirror)) { ForEach(RepeaterSettings.Mirror.allCases) { Text($0.rawValue).tag($0) } }
            ValueSlider(label: "Distance", value: $s.mirrorGap, range: -400...800, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            if s.mirror == .kaleidoscope {
                ValueSlider(label: "Segments", value: int(\.segments), range: 2...24, step: 1, labelWidth: labelWidth, onCommit: onCommit)
            }
        case .scatter:
            ValueSlider(label: "Count", value: int(\.count), range: 1...200, step: 1, labelWidth: labelWidth, onCommit: onCommit)
            Picker("Inside", selection: pick(\.region)) { ForEach(RepeaterSettings.Region.allCases) { Text($0.rawValue).tag($0) } }
            if s.region == .custom { HStack { Text("Custom shape").foregroundStyle(Theme.textDim); ShapeLibraryPicker(id: pick(\.customID)) } }
            if s.region == .captured {
                Text(s.captured == nil ? "Make a selection (or select a path) before choosing Repeat…" : "Uses the selection / path from when the repeater was made.")
                    .font(Theme.fontSmall).foregroundStyle(s.captured == nil ? .orange : Theme.textFaint)
            } else {
                ValueSlider(label: "Width", value: $s.regionWidth, range: 10...4000, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
                ValueSlider(label: "Height", value: $s.regionHeight, range: 10...4000, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            }
            ValueSlider(label: "Min distance", value: $s.minDistance, range: 0...600, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            Toggle2(label: "No overlap", on: pick(\.noOverlap))
        }
        DisclosureGroup("Each instance") {
            ValueSlider(label: "Offset X", value: $s.stepX, range: -200...200, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Offset Y", value: $s.stepY, range: -200...200, unit: "px", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Rotate", value: $s.stepRotation, range: -180...180, unit: "°", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Scale", value: $s.stepScale, range: 50...150, unit: "%", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Fade", value: $s.stepOpacity, range: 0...50, unit: "%", format: "%.1f", labelWidth: labelWidth, onCommit: onCommit)
        }
        DisclosureGroup("Random variation") {
            ValueSlider(label: "Hue", value: $s.varyHue, range: 0...180, unit: "°", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Brightness", value: $s.varyBrightness, range: 0...100, unit: "%", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Rotation", value: $s.varyRotation, range: 0...180, unit: "°", labelWidth: labelWidth, onCommit: onCommit)
            ValueSlider(label: "Scale", value: $s.varyScale, range: 0...90, unit: "%", labelWidth: labelWidth, onCommit: onCommit)
        }
        HStack {
            NumberField(label: "Seed", value: Binding(get: { Double(s.seed) }, set: { s.seed = max(1, Int($0)) }), width: 44, onCommit: onCommit)
            Button("Shuffle") { s.seed = Int.random(in: 1...9999); onCommit() }.buttonStyle(PanelButtonStyle())
        }
    }
}

/// Layer ▸ Repeater ▸ Repeat…: wraps the selection in a repeater (or edits the active one) with a live preview.
struct RepeaterDialog: View {
    @State private var s = RepeaterSettings()
    @State private var groupID: UUID?
    @State private var editing = false
    @State private var showGuide = true
    @State private var session = LayoutPreviewSession()

    var body: some View {
        DialogFrame(title: editing ? "Edit Repeater" : "Repeat", width: 360, onOK: { finish(true) }, onCancel: { finish(false) }) {
            if groupID == nil {
                Text("Select the layer (or layers) to repeat.").foregroundStyle(Theme.textFaint)
            } else {
                RepeaterControls(s: $s)
                Toggle2(label: "Show guide", on: $showGuide)
                Text("The source stays a normal layer inside the Repeater group — edit it and every copy updates. Layer ▸ Repeater ▸ Expand makes them real layers.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { begin() }
        .onChange(of: s) { _, _ in update() }
        .onChange(of: showGuide) { _, _ in update() }
    }

    private func begin() {
        guard groupID == nil, let d = AppActions.doc else { return }
        session.begin()
        if let id = RepeaterActions.activeRepeater(d), let cur = RepeaterActions.settings(d.state.layer(id)) {
            editing = true
            groupID = id
            s = cur
        } else {
            let ids = d.orderedSelection.filter { d.state.layer($0).map { !$0.isAdjustment } ?? false }
            guard let b = LayoutGeom.union(LayoutGeom.items(ids, d.state).map(\.rect)) else { return }
            let start = RepeaterActions.defaults(source: b, doc: d)
            groupID = RepeaterActions.make(d, ids: ids, settings: start)
            s = start
        }
        update()
    }

    private func update() {
        guard let d = AppActions.doc, let id = groupID else { return }
        RepeaterActions.update(&d.state, id, s)
        var guide: CGPath?
        if showGuide, case .group(let g)? = d.state.layer(id)?.content,
           let b = RepeaterRenderer.sourceBounds(g, width: d.state.width, height: d.state.height) {
            guide = RepeaterLayout.guide(s, source: b)
        }
        ArrangeGuide.path = guide
        d.setNeedsRender()
        AppActions.canvas?.overlay.needsDisplay = true
    }

    private func finish(_ apply: Bool) {
        guard groupID != nil else { ArrangeGuide.path = nil; return }
        session.finish(apply: apply, name: editing ? "Edit Repeater" : "Repeat")
    }
}

/// Properties panel section for a repeater group.
struct RepeaterProperties: View {
    @Bindable var doc: Document
    let layerID: UUID
    let settings: RepeaterSettings

    var body: some View {
        Caption("Repeater")
        RepeaterControls(s: Binding(get: { settings }, set: { v in RepeaterActions.update(&doc.state, layerID, v) }), labelWidth: 78,
                         onCommit: { doc.commit("Edit Repeater") })
        HStack {
            Button("Expand") { RepeaterActions.expand(doc, layerID) }.buttonStyle(PanelButtonStyle())
                .help("Convert the instances into real, independent layers")
            Button("Release") { RepeaterActions.release(doc, layerID) }.buttonStyle(PanelButtonStyle())
                .help("Remove the repeater and keep only the source layers")
        }
        Text(settings.summary).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
    }
}
