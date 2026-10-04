import SwiftUI
import ImageCratCore

/// Layers panel, second pass: effect visibility per effect (Photoshop's eyes under "fx"), group disclosure that survives
/// Undo / Cancel and is saved with the document, auto-reveal of layers picked on the canvas, the Layer ▸ Layer Style
/// commands Hide / Show All Effects and Scale Effects…, and the Move tool's auto-select (Tools/AutoSelect.swift).
enum LayersPanel2Module {
    static func register() {
        let style = "Layer/Layer Style"
        MenuRegistry.add(style, "Hide All Effects", enabled: { AppActions.doc.map(LayerFX.anyEffectsShown) ?? false }) {
            if let d = AppActions.doc { LayerFX.setAllEffects(d, shown: false) }
        }
        MenuRegistry.add(style, "Show All Effects", enabled: { AppActions.doc.map(LayerFX.anyEffectsHidden) ?? false }) {
            if let d = AppActions.doc { LayerFX.setAllEffects(d, shown: true) }
        }
        MenuRegistry.add(style, "Scale Effects…", enabled: { AppActions.doc.map { !LayerFX.styledSelection($0).isEmpty } ?? false }) {
            DialogRegistry.show(ScaleEffectsDialog.id)
        }
        DialogRegistry.register(ScaleEffectsDialog.id) { AnyView(ScaleEffectsDialog()) }
        FeatureModules.selfTests.append(("layerspanel2", { LayersPanel2SelfTest.run($0) }))
    }
}

/// Panel-only state that is not part of the document.
@Observable
final class LayersPanelUI {
    static let shared = LayersPanelUI()
    /// Layers whose effect list is folded up (the triangle next to "fx"); effect lists are open by default.
    var fxCollapsed: Set<UUID> = []
    /// Bumped to make the panel scroll a layer into view (auto-reveal after picking it on the canvas).
    var reveal: (id: UUID, tick: Int)? = nil
}

// MARK: - Effect visibility

enum LayerFX {
    /// The "Effects" eye: the layer's master switch. The individual eyes keep their state.
    static func toggleMaster(_ d: Document, _ id: UUID) {
        guard let l = d.state.layer(id), l.effects.hasStyle else { return }
        let on = !l.effects.enabled
        d.updateLayer(id) { $0.effects.enabled = on }
        d.commit(on ? "Show Layer Effects" : "Hide Layer Effects")
    }

    /// The eye of one effect: hides or shows it, keeping its settings. Showing an effect of a layer whose master switch
    /// is off switches the master on too (the other effects keep their own eyes).
    static func setShown(_ d: Document, _ id: UUID, _ slot: EffectSlot, _ on: Bool) {
        guard let l = d.state.layer(id), l.effects.item(slot)?.isListed == true else { return }
        if l.effects.isShown(slot) == on && (!on || l.effects.enabled) { return }
        d.updateLayer(id) { x in
            x.effects.setShown(slot, on)
            if on { x.effects.enabled = true }
        }
        d.commit("\(on ? "Show" : "Hide") \(slot.kind.displayName)")
    }

    /// Layers of the document that have a style.
    static func styled(_ d: Document) -> [Layer] { d.state.allLayers.filter { $0.effects.hasStyle } }
    /// Selected layers that have a style.
    static func styledSelection(_ d: Document) -> [UUID] { d.orderedSelection.filter { d.state.layer($0)?.effects.hasStyle == true } }

    static func anyEffectsShown(_ d: Document) -> Bool { styled(d).contains { $0.effects.enabled } }
    static func anyEffectsHidden(_ d: Document) -> Bool { styled(d).contains { !$0.effects.enabled } }

    /// Layer ▸ Layer Style ▸ Hide All Effects / Show All Effects: the master switch of every layer of the document
    /// (like Photoshop), one history step. Nothing is deleted.
    static func setAllEffects(_ d: Document, shown: Bool) {
        let ids = styled(d).filter { $0.effects.enabled != shown }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { d.updateLayer(id) { $0.effects.enabled = shown } }
        d.commit(shown ? "Show All Effects" : "Hide All Effects")
    }

    /// Layer ▸ Layer Style ▸ Scale Effects: sizes and distances of every effect of `ids` by `factor`, from `base`.
    static func scaleEffects(_ d: Document, base: [UUID: LayerEffects], factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        for (id, fx) in base { d.updateLayer(id) { $0.effects = LayerTransformer.scaled(fx, factor) } }
    }

    /// Double-click on an effect row: Layer Style opened on that effect (and instance), which is not switched on.
    static func openStyle(_ slot: EffectSlot, layer id: UUID, doc d: Document) {
        guard let s = StyleSection(rawValue: slot.kind.displayName) else { return }
        d.selectLayer(id)
        LayerStyleDialog.reveal(s, instance: slot.index, layer: id, doc: d)
    }
}

// MARK: - Group disclosure

enum LayerGroups {
    /// Sets the disclosure state of `ids` (groups) as a view-only change: no history step, not undone, saved with the
    /// document (`Document.applyViewOnlyChange`).
    static func setExpanded(_ d: Document, _ ids: [UUID], _ on: Bool) {
        let change = ids.filter { d.state.layer($0).map { $0.isGroup && $0.isExpanded != on } ?? false }
        guard !change.isEmpty else { return }
        d.applyViewOnlyChange { st in for id in change { st.updateLayer(id) { $0.isExpanded = on } } }
    }

    /// The triangle: toggles the group; ⌥-click (`recursive`) applies the new state to every group nested inside too.
    static func toggle(_ d: Document, _ id: UUID, recursive: Bool) {
        guard let g = d.state.layer(id), g.isGroup else { return }
        let on = !g.isExpanded
        let ids = recursive ? g.allIDs.filter { d.state.layer($0)?.isGroup == true } : [id]
        setExpanded(d, ids, on)   // (the selection is left alone: a collapsed group may hide the active layer, like Photoshop)
    }

    static func allGroupIDs(_ d: Document) -> [UUID] { d.state.allLayers.filter(\.isGroup).map(\.id) }

    /// Panel menu ▸ Collapse All Groups / Expand All Groups.
    static func collapseAll(_ d: Document) { setExpanded(d, allGroupIDs(d), false) }
    static func expandAll(_ d: Document) { setExpanded(d, allGroupIDs(d), true) }

    /// Groups containing `id`, outermost first.
    static func ancestors(_ d: Document, _ id: UUID) -> [UUID] {
        guard let path = d.state.layers.indexPath(of: id), path.count > 1 else { return [] }
        var out: [UUID] = []
        for n in 1..<path.count { out.append(d.state.layers[path: Array(path.prefix(n))].id) }
        return out
    }

    /// Auto-reveal: opens the groups around `id` and asks the panel to scroll it into view.
    static func reveal(_ d: Document, _ id: UUID) {
        setExpanded(d, ancestors(d, id), true)
        let t = (LayersPanelUI.shared.reveal?.tick ?? 0) + 1
        LayersPanelUI.shared.reveal = (id, t)
    }
}

// MARK: - Effect rows under a layer

/// "Effects" with its eye, then one row per effect of the style with its own eye (hidden effects stay listed).
struct LayerEffectsRows: View {
    @Bindable var doc: Document
    let layer: Layer
    let depth: Int

    var selected: Bool { doc.selectedLayerIDs.contains(layer.id) }

    var body: some View {
        let fx = layer.effects
        VStack(spacing: 0) {
            row(.effects(layer.id), eyeOn: fx.enabled, label: "Effects", labelDim: !fx.enabled, indent: 0, height: 19,
                axLabel: fx.enabled ? "Hide Effects" : "Show Effects", eye: { LayerFX.toggleMaster(doc, layer.id) }, open: nil)
            ForEach(fx.listedSlots, id: \.self) { s in
                let shown = fx.isShown(s)
                let name = s.kind.displayName + (s.index > 0 ? " \(s.index + 1)" : "")
                row(.effect(layer.id, s), eyeOn: shown, label: s.kind.displayName, labelDim: !shown || !fx.enabled, indent: 14, height: 18, masterOff: !fx.enabled,
                    axLabel: (shown ? "Hide " : "Show ") + name,
                    eye: { LayerFX.setShown(doc, layer.id, s, !shown) },
                    open: { LayerFX.openStyle(s, layer: layer.id, doc: doc) })
            }
        }
        .background(selected ? Theme.selection.opacity(0.35) : Color.clear)
        .overlay(Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    func row(_ target: EyeTarget, eyeOn: Bool, label: String, labelDim: Bool, indent: CGFloat, height: CGFloat, masterOff: Bool = false, axLabel: String,
             eye: @escaping () -> Void, open: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            Button(action: eye) {
                Image(systemName: eyeOn ? "eye" : "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(eyeOn && !masterOff ? Theme.text : Theme.textFaint)
                    .frame(width: 22, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(axLabel)
            .help(axLabel)
            Rectangle().fill(Theme.border).frame(width: 1)
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(depth) * 14 + 20 + indent)
                if indent == 0 {
                    Text("fx").font(.system(size: 10, weight: .bold, design: .serif)).italic().foregroundStyle(labelDim ? Theme.textFaint : Theme.textDim)
                }
                Text(label).font(Theme.fontSmall).foregroundStyle(labelDim ? Theme.textFaint : Theme.textDim).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { (open ?? { AppModel.shared.dialog = .layerStyle(layer.id) })() })
            .simultaneousGesture(TapGesture().onEnded { if !doc.selectedLayerIDs.contains(layer.id) { doc.selectLayer(layer.id) } })
        }
        .frame(height: height)
        .eyeRow(target)   // (drag across effect eyes: LayersPanelEyeDrag.swift)
    }
}

// MARK: - Scale Effects

/// Layer ▸ Layer Style ▸ Scale Effects…: scales sizes and distances of the selected layers' styles (live preview).
struct ScaleEffectsDialog: View {
    static let id = "layerspanel2.scaleEffects"
    @State private var percent: Double = 100
    @State private var base: [UUID: LayerEffects] = [:]

    var body: some View {
        DialogFrame(title: "Scale Layer Effects", width: 340, onOK: {
            guard let d = AppActions.doc, !base.isEmpty, abs(percent - 100) > 0.001 else { return }
            LayerFX.scaleEffects(d, base: base, factor: percent / 100)
            d.commit("Scale Effects")
        }, onCancel: { AppActions.doc?.revertUncommitted() }) {
            ValueSlider(label: "Scale", value: Binding(get: { percent }, set: { v in
                percent = clamp(v, 1, 1000)
                if let d = AppActions.doc { LayerFX.scaleEffects(d, base: base, factor: percent / 100) }
            }), range: 1...1000, unit: "%")
            Text(base.isEmpty ? "The selected layers have no layer style." : "Scales sizes, distances and pattern scale of \(base.count == 1 ? "the layer’s style" : "\(base.count) layer styles").")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .onAppear {
            guard let d = AppActions.doc else { return }
            var b: [UUID: LayerEffects] = [:]
            for id in LayerFX.styledSelection(d) { if let l = d.state.layer(id) { b[id] = l.effects } }
            base = b
        }
    }
}
