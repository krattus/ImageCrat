import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageCratCore

/// Compact label + value bar that scrubs horizontally (used inside nodes).
struct RecipeScrubber: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var integer = false
    var unit = ""
    var driven = false
    let onChange: (Double) -> Void
    let onCommit: () -> Void
    @State private var start: Double?

    static func format(_ v: Double, range: ClosedRange<Double>, integer: Bool) -> String {
        if integer { return String(format: "%.0f", v) }
        let span = range.upperBound - range.lowerBound
        return String(format: span <= 2.5 ? "%.2f" : (span <= 40 ? "%.1f" : (abs(v) < 100 && span > 2000 ? "%.2f" : "%.0f")), v)
    }

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 && span <= 2000 ? CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG)
                if !driven { RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.4)).frame(width: max(0, geo.size.width * frac)) }
                HStack(spacing: 4) {
                    Text(tr(label)).lineLimit(1).foregroundStyle(driven ? Theme.textFaint : Theme.text)
                    Spacer(minLength: 2)
                    Text(tr(driven ? "linked" : Self.format(value, range: range, integer: integer) + unit)).font(Theme.mono).foregroundStyle(driven ? Theme.textFaint : Theme.textDim).lineLimit(1)
                }
                .font(Theme.fontSmall)
                .padding(.horizontal, 5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                guard !driven else { return }
                if start == nil { start = value }
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1.0
                let perPoint = span <= 2000 ? span / Double(max(geo.size.width, 40)) : max(0.01, abs(start ?? 0) * 0.01)
                var nv = (start ?? value) + Double(v.translation.width) * perPoint * fine
                nv = min(max(nv, range.lowerBound), range.upperBound)
                if integer { nv = nv.rounded() }
                onChange(nv)
            }.onEnded { _ in
                if start != nil { start = nil; onCommit() }
            })
        }
    }
}

/// Menu listing the document's layers (for Layer / Layer Mask input nodes).
struct RecipeLayerPicker: View {
    let layers: [Layer]
    let selected: String
    var allowNone = false
    let onPick: (String) -> Void

    var body: some View {
        let current = layers.first { $0.id.uuidString == selected }
        Menu {
            if allowNone { Button("This Layer") { onPick("") } }
            ForEach(layers.reversed()) { l in
                Button { onPick(l.id.uuidString) } label: {
                    if l.id.uuidString == selected { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                }
            }
        } label: {
            Text(tr(current?.name ?? (selected.isEmpty ? (allowNone ? "This Layer" : "Choose…") : "Missing layer"))).font(Theme.font)
                .foregroundStyle(current == nil && !selected.isEmpty ? Color.orange : Theme.text)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
    }
}

/// Full-size editor for one node parameter (Recipe Editor inspector and the Properties panel).
struct RecipeParamControl: View {
    let spec: RecipeParamSpec
    var label: String? = nil
    let node: RecipeNode
    var layers: [Layer] = []
    /// Live edit (uncommitted).
    let edit: (@escaping (inout RecipeNode) -> Void) -> Void
    /// Records the history step.
    let commit: () -> Void
    var labelWidth: CGFloat = 84

    private var title: String { label ?? spec.label }
    private var number: Double { node.numbers[spec.key] ?? spec.def }

    var body: some View {
        switch spec.kind {
        case .slider(let r):
            let span = r.upperBound - r.lowerBound
            ValueSlider(label: title, value: Binding(get: { number }, set: { v in edit { $0.numbers[spec.key] = v } }), range: r, unit: spec.unit,
                        format: span <= 2.5 ? "%.2f" : (span <= 40 ? "%.1f" : "%.0f"), labelWidth: labelWidth, onCommit: commit)
        case .int(let r):
            ValueSlider(label: title, value: Binding(get: { number }, set: { v in edit { $0.numbers[spec.key] = v.rounded() } }), range: r, step: 1, labelWidth: labelWidth, onCommit: commit)
        case .angle:
            ValueSlider(label: title, value: Binding(get: { number }, set: { v in edit { $0.numbers[spec.key] = v } }), range: -180...180, unit: "°", labelWidth: labelWidth, onCommit: commit)
        case .seed:
            HStack(spacing: 4) {
                ValueSlider(label: title, value: Binding(get: { number }, set: { v in edit { $0.numbers[spec.key] = v.rounded() } }), range: 0...9999, step: 1, labelWidth: labelWidth, onCommit: commit)
                Button { let s = Double(Int.random(in: 0...9999)); edit { $0.numbers[spec.key] = s }; commit() } label: { Image(systemName: "dice") }
                    .buttonStyle(.plain).help("Random seed")
            }
        case .toggle:
            Toggle2(label: title, on: Binding(get: { number > 0.5 }, set: { v in edit { $0.numbers[spec.key] = v ? 1 : 0 }; commit() }))
        case .choice(let opts):
            HStack {
                Text(tr(title)).foregroundStyle(Theme.textDim).frame(width: labelWidth, alignment: .leading).lineLimit(1)
                Picker("", selection: Binding(get: { min(max(0, Int(number)), max(0, opts.count - 1)) }, set: { v in edit { $0.numbers[spec.key] = Double(v) }; commit() })) {
                    ForEach(Array(opts.enumerated()), id: \.offset) { i, o in Text(tr(o)).tag(i) }
                }.labelsHidden()
            }
        case .color:
            HStack {
                Text(tr(title)).foregroundStyle(Theme.textDim).frame(width: labelWidth, alignment: .leading).lineLimit(1)
                ColorWell(color: Binding(get: { node.colors[spec.key] ?? spec.defColor }, set: { v in edit { $0.colors[spec.key] = v } }), size: 18, showAlpha: true, onCommit: commit)
                Text("#" + (node.colors[spec.key] ?? spec.defColor).hex).font(Theme.mono).foregroundStyle(Theme.textFaint)
                Spacer()
            }
        case .point:
            let p = node.vectors[spec.key] ?? spec.defPoint
            VStack(alignment: .leading, spacing: 3) {
                ValueSlider(label: title + " X", value: Binding(get: { Double(p.x) * 100 }, set: { v in edit { $0.vectors[spec.key] = CGPoint(x: v / 100, y: Double(p.y)) } }),
                            range: 0...100, unit: "%", labelWidth: labelWidth, onCommit: commit)
                ValueSlider(label: title + " Y", value: Binding(get: { Double(p.y) * 100 }, set: { v in edit { $0.vectors[spec.key] = CGPoint(x: Double(p.x), y: v / 100) } }),
                            range: 0...100, unit: "%", labelWidth: labelWidth, onCommit: commit)
            }
        case .gradient:
            let g = node.gradients[spec.key] ?? spec.defGradient ?? .twoColor(.black, .white)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr(title)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Menu("Presets") {
                        ForEach(AppModel.shared.gradients) { pg in Button(tr(pg.name)) { edit { $0.gradients[spec.key] = pg }; commit() } }
                        Divider()
                        Button("Reverse") { let r = g.reversed(); edit { $0.gradients[spec.key] = r }; commit() }
                        if let d = spec.defGradient { Button("Reset") { edit { $0.gradients[spec.key] = d }; commit() } }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                GradientStopsEditor(gradient: Binding(get: { g }, set: { v in edit { $0.gradients[spec.key] = v } }), onCommit: commit).padding(.horizontal, 7)
            }
        case .curve:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr(title)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Reset") { edit { $0.curves[spec.key] = CurvePoints() }; commit() }.buttonStyle(.plain).foregroundStyle(Theme.textDim)
                }
                CurveEditor(curve: Binding(get: { node.curves[spec.key] ?? CurvePoints() }, set: { v in edit { $0.curves[spec.key] = v } }), hist: nil, channel: 0, color: .white, onCommit: commit)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        case .text:
            HStack {
                Text(tr(title)).foregroundStyle(Theme.textDim).frame(width: labelWidth, alignment: .leading)
                TextField("", text: Binding(get: { node.strings[spec.key] ?? spec.defString }, set: { v in edit { $0.strings[spec.key] = v } }))
                    .textFieldStyle(.roundedBorder).onSubmit(commit)
            }
        case .file:
            let path = node.strings[spec.key] ?? ""
            HStack {
                Text(tr(title)).foregroundStyle(Theme.textDim).frame(width: labelWidth, alignment: .leading)
                Text(tr(path.isEmpty ? "None" : (path as NSString).lastPathComponent)).lineLimit(1).truncationMode(.middle).help(path)
                Spacer()
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = spec.key == "path" && spec.label.contains("cube") ? [UTType(filenameExtension: "cube") ?? .data] : [.image]
                    if p.runModal() == .OK, let u = p.url { edit { $0.strings[spec.key] = u.path }; commit() }
                }.buttonStyle(PanelButtonStyle())
            }
        case .layer:
            HStack {
                Text(tr(title)).foregroundStyle(Theme.textDim).frame(width: labelWidth, alignment: .leading).lineLimit(1)
                RecipeLayerPicker(layers: layers, selected: node.strings[spec.key] ?? "", allowNone: spec.label.contains("empty")) { v in
                    edit { $0.strings[spec.key] = v }; commit()
                }
                Spacer()
            }
        }
    }
}
