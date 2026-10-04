import SwiftUI
import ImageCratCore

enum StyleSection: String, CaseIterable, Identifiable {
    case blending = "Blending Options"
    case bevel = "Bevel & Emboss"
    case stroke = "Stroke"
    case innerShadow = "Inner Shadow"
    case innerGlow = "Inner Glow"
    case satin = "Satin"
    case colorOverlay = "Color Overlay"
    case gradientOverlay = "Gradient Overlay"
    case patternOverlay = "Pattern Overlay"
    case outerGlow = "Outer Glow"
    case dropShadow = "Drop Shadow"
    var id: String { rawValue }

    /// Effects Photoshop lets you add several times ("+").
    var allowsMultiple: Bool { [.stroke, .innerShadow, .colorOverlay, .gradientOverlay, .dropShadow].contains(self) }
}

struct LayerStyleDialog: View {
    let layerID: UUID
    @State private var section: StyleSection
    @State private var instance = 0

    /// Section the next Layer Style dialog for that layer opens on (fx menu ▸ Drop Shadow… etc.); cleared when it closes.
    static var openingSection: (layer: UUID, section: StyleSection)?
    /// Instance of a multi-instance effect the dialog opens on (with `openingSection`).
    static var openingInstance = 0

    init(layerID: UUID) {
        self.layerID = layerID
        let s = Self.openingSection
        _section = State(initialValue: s?.layer == layerID ? s!.section : .blending)
        _instance = State(initialValue: s?.layer == layerID ? Self.openingInstance : 0)
    }

    /// Opens the dialog on instance `instance` of `section` as it is (an effect hidden with its eye stays hidden):
    /// double-clicking an effect row in the Layers panel.
    static func reveal(_ section: StyleSection, instance: Int, layer id: UUID, doc d: Document) {
        AppModel.shared.dialog = .layerStyle(id)
        openingSection = (id, section)
        openingInstance = instance
    }

    /// Opens the dialog on `section` with that effect switched on (a live edit, so Cancel switches it off again), like
    /// choosing it from Photoshop's fx menu.
    static func open(_ section: StyleSection, layer id: UUID, doc d: Document) {
        if section != .blending {
            d.updateLayer(id) { l in
                switch section {
                case .blending: break
                case .bevel: l.effects.bevel.enabled = true
                case .stroke: l.effects.stroke.enabled = true
                case .innerShadow: l.effects.innerShadow.enabled = true
                case .innerGlow: l.effects.innerGlow.enabled = true
                case .satin: l.effects.satin.enabled = true
                case .colorOverlay: l.effects.colorOverlay.enabled = true
                case .gradientOverlay: l.effects.gradientOverlay.enabled = true
                case .patternOverlay: l.effects.patternOverlay.enabled = true
                case .outerGlow: l.effects.outerGlow.enabled = true
                case .dropShadow: l.effects.dropShadow.enabled = true
                }
                l.effects.enabled = true
            }
        }
        AppModel.shared.dialog = .layerStyle(id)
        openingSection = (id, section)       // (after: replacing another dialog clears it — DialogGuard)
        openingInstance = 0
    }

    var doc: Document? { AppActions.doc }
    var layer: Layer? { doc?.state.layer(layerID) }

    func fxBinding() -> Binding<LayerEffects> {
        Binding(get: { layer?.effects ?? LayerEffects() }, set: { v in doc?.updateLayer(layerID) { $0.effects = v } })
    }

    var body: some View {
        let fx = fxBinding()
        VStack(alignment: .leading, spacing: 10) {
            Text("Layer Style — \(layer?.name ?? "")").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(StyleSection.allCases) { s in
                        ForEach(0..<instanceCount(s, fx), id: \.self) { i in
                            styleRow(s, i, fx)
                        }
                    }
                    Spacer()
                    HStack {
                        Button("Presets") {}.hidden()
                    }
                }
                .frame(width: 170)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionView(fx)
                    }
                    .frame(width: 330, alignment: .leading)
                    .padding(.trailing, 6)
                }
                .frame(height: 420)
            }
            HStack {
                Menu("Style Presets") {
                    Button("Soft Drop Shadow") { applyPreset { $0.dropShadow = ShadowEffect(enabled: true, opacity: 0.45, distance: 8, size: 18) } }
                    Button("Neon Glow") { applyPreset { $0.outerGlow = GlowEffect(enabled: true, color: RGBA(hex: "00E5FF")!, opacity: 0.9, spread: 10, size: 24); $0.stroke = StrokeEffect(enabled: true, size: 2, position: .outside, paint: .color(RGBA(hex: "B3F5FF")!)) } }
                    Button("Embossed") { applyPreset { $0.bevel = BevelEffect(enabled: true, style: .innerBevel, depth: 150, size: 8, soften: 2); $0.dropShadow = ShadowEffect(enabled: true, opacity: 0.4, distance: 4, size: 6) } }
                    Button("Gold") { applyPreset {
                        $0.gradientOverlay = GradientOverlayEffect(enabled: true, fill: GradientFill(gradient: ColorGradient.presets.first { $0.name == "Copper" } ?? ColorGradient.presets[0], angle: 90))
                        $0.bevel = BevelEffect(enabled: true, style: .innerBevel, technique: .chiselSoft, depth: 200, size: 6)
                        $0.dropShadow = ShadowEffect(enabled: true, opacity: 0.5, distance: 5, size: 8)
                    } }
                    Button("Sticker") { applyPreset { $0.stroke = StrokeEffect(enabled: true, size: 10, position: .outside, paint: .color(.white)); $0.dropShadow = ShadowEffect(enabled: true, opacity: 0.35, distance: 6, size: 12) } }
                    Button("Letterpress") { applyPreset { $0.innerShadow = ShadowEffect(enabled: true, opacity: 0.6, angle: 90, distance: 2, size: 3); $0.dropShadow = ShadowEffect(enabled: true, blendMode: .screen, color: .white, opacity: 0.5, angle: 90, distance: 1, size: 0) } }
                    Divider()
                    Button("Clear All") { applyPreset { $0 = LayerEffects() } }
                }
                .frame(width: 130)
                Spacer()
                Button("Cancel") { doc?.revertUncommitted(); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { FieldEdits.commit(); doc?.commit("Layer Style"); AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder func styleRow(_ s: StyleSection, _ i: Int, _ fx: Binding<LayerEffects>) -> some View {
        let selected = section == s && (instance == i || !s.allowsMultiple)
        HStack(spacing: 6) {
            if s != .blending {
                Toggle("", isOn: enabledBinding(s, i, fx)).toggleStyle(.checkbox).labelsHidden()
            } else {
                Spacer().frame(width: 16)
            }
            Button {
                section = s
                instance = i
                if s != .blending && !enabledBinding(s, i, fx).wrappedValue { enabledBinding(s, i, fx).wrappedValue = true }
            } label: {
                HStack {
                    Text(s.rawValue).font(selected ? Theme.fontBold : Theme.font).foregroundStyle(Theme.text)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if s.allowsMultiple {
                if i > 0 {
                    Button { removeInstance(s, i, fx) } label: { Image(systemName: "minus").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Delete this \(s.rawValue)")
                }
                Button { addInstance(s, after: i, fx) } label: { Image(systemName: "plus").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim).help("Add another \(s.rawValue)")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.selection : .clear))
    }

    func instanceCount(_ s: StyleSection, _ fx: Binding<LayerEffects>) -> Int {
        let f = fx.wrappedValue
        switch s {
        case .stroke: return 1 + f.extraStrokes.count
        case .innerShadow: return 1 + f.extraInnerShadows.count
        case .colorOverlay: return 1 + f.extraColorOverlays.count
        case .gradientOverlay: return 1 + f.extraGradientOverlays.count
        case .dropShadow: return 1 + f.extraDropShadows.count
        default: return 1
        }
    }

    /// Binding to instance `i` of a multi-instance effect (0 = primary).
    func inst<T>(_ primary: WritableKeyPath<LayerEffects, T>, _ extras: WritableKeyPath<LayerEffects, [T]>, _ i: Int, _ fx: Binding<LayerEffects>) -> Binding<T> {
        Binding(get: {
            let f = fx.wrappedValue
            if i > 0, f[keyPath: extras].indices.contains(i - 1) { return f[keyPath: extras][i - 1] }
            return f[keyPath: primary]
        }, set: { v in
            var f = fx.wrappedValue
            if i == 0 { f[keyPath: primary] = v } else if f[keyPath: extras].indices.contains(i - 1) { f[keyPath: extras][i - 1] = v }
            fx.wrappedValue = f
        })
    }

    func addInstance(_ s: StyleSection, after i: Int, _ fx: Binding<LayerEffects>) {
        var f = fx.wrappedValue
        func insert<T>(_ primary: WritableKeyPath<LayerEffects, T>, _ extras: WritableKeyPath<LayerEffects, [T]>, enable: (inout T) -> Void) {
            var copy = i == 0 ? f[keyPath: primary] : f[keyPath: extras][i - 1]
            enable(&copy)
            f[keyPath: extras].insert(copy, at: min(i, f[keyPath: extras].count))
        }
        switch s {
        case .stroke: insert(\.stroke, \.extraStrokes) { $0.enabled = true }
        case .innerShadow: insert(\.innerShadow, \.extraInnerShadows) { $0.enabled = true }
        case .colorOverlay: insert(\.colorOverlay, \.extraColorOverlays) { $0.enabled = true }
        case .gradientOverlay: insert(\.gradientOverlay, \.extraGradientOverlays) { $0.enabled = true }
        case .dropShadow: insert(\.dropShadow, \.extraDropShadows) { $0.enabled = true }
        default: return
        }
        f.enabled = true
        fx.wrappedValue = f
        section = s
        instance = i + 1
    }

    func removeInstance(_ s: StyleSection, _ i: Int, _ fx: Binding<LayerEffects>) {
        guard i > 0 else { return }
        var f = fx.wrappedValue
        switch s {
        case .stroke: f.extraStrokes.remove(at: i - 1)
        case .innerShadow: f.extraInnerShadows.remove(at: i - 1)
        case .colorOverlay: f.extraColorOverlays.remove(at: i - 1)
        case .gradientOverlay: f.extraGradientOverlays.remove(at: i - 1)
        case .dropShadow: f.extraDropShadows.remove(at: i - 1)
        default: return
        }
        fx.wrappedValue = f
        if section == s && instance >= i { instance = max(0, instance - 1) }
    }

    func applyPreset(_ f: (inout LayerEffects) -> Void) {
        var fx = layer?.effects ?? LayerEffects()
        f(&fx)
        fx.enabled = true
        doc?.updateLayer(layerID) { $0.effects = fx }
    }

    /// The checkbox adds the effect to / removes it from the style (an effect hidden with its eye in the Layers panel
    /// shows unchecked; checking it shows it again). Settings are kept either way.
    func enabledBinding(_ s: StyleSection, _ i: Int, _ fx: Binding<LayerEffects>) -> Binding<Bool> {
        guard let kind = EffectKind.allCases.first(where: { $0.displayName == s.rawValue }) else { return .constant(true) }
        let slot = EffectSlot(kind: kind, index: i)
        return Binding(get: { fx.wrappedValue.item(slot)?.enabled == true }, set: { v in
            var f = fx.wrappedValue
            f.modify(slot) { $0.setInStyle(v) }
            fx.wrappedValue = f
        })
    }

    @ViewBuilder func sectionView(_ fx: Binding<LayerEffects>) -> some View {
        switch section {
        case .blending: blending
        case .bevel: bevelView(fx.bevel)
        case .stroke: strokeView(inst(\.stroke, \.extraStrokes, instance, fx))
        case .innerShadow: shadowView(inst(\.innerShadow, \.extraInnerShadows, instance, fx), inner: true)
        case .innerGlow: glowView(fx.innerGlow, inner: true)
        case .satin: satinView(fx.satin)
        case .colorOverlay:
            let c = inst(\.colorOverlay, \.extraColorOverlays, instance, fx)
            Caption("Color Overlay")
            modeRow(c.blendMode, color: c.color)
            pct("Opacity", c.opacity)
        case .gradientOverlay:
            let g = inst(\.gradientOverlay, \.extraGradientOverlays, instance, fx)
            Caption("Gradient Overlay")
            modeRow(g.blendMode, color: nil)
            pct("Opacity", g.opacity)
            GradientFillEditor(fill: g.fill)
        case .patternOverlay:
            Caption("Pattern Overlay")
            modeRow(fx.patternOverlay.blendMode, color: nil)
            pct("Opacity", fx.patternOverlay.opacity)
            HStack { Text("Pattern").foregroundStyle(Theme.textDim); PatternPicker(patternID: fx.patternOverlay.patternID) }
            ValueSlider(label: "Scale", value: Binding(get: { fx.patternOverlay.scale.wrappedValue * 100 }, set: { fx.patternOverlay.scale.wrappedValue = $0 / 100 }), range: 1...1000, unit: "%")
        case .outerGlow: glowView(fx.outerGlow, inner: false)
        case .dropShadow: shadowView(inst(\.dropShadow, \.extraDropShadows, instance, fx), inner: false)
        }
    }

    // MARK: Sections

    @ViewBuilder var blending: some View {
        if let l = layer {
            let lb = Binding<Layer>(get: { layer ?? l }, set: { v in doc?.updateLayer(layerID) { cur in
                var n = v
                if cur.locks.propertiesLocked { n.blendMode = cur.blendMode; n.opacity = cur.opacity; n.fillOpacity = cur.fillOpacity }   // Lock All
                cur = n
            } })
            Caption("General Blending")
            HStack {
                Text("Blend Mode").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
                BlendModePicker(mode: lb.blendMode, includePassThrough: l.isGroup).disabled(l.locks.propertiesLocked)
            }
            ValueSlider(label: "Opacity", value: Binding(get: { lb.wrappedValue.opacity * 100 }, set: { lb.wrappedValue.opacity = $0 / 100 }), range: 0...100, unit: "%")
                .disabled(l.locks.propertiesLocked)
            Caption("Advanced Blending")
            ValueSlider(label: "Fill Opacity", value: Binding(get: { lb.wrappedValue.fillOpacity * 100 }, set: { lb.wrappedValue.fillOpacity = $0 / 100 }), range: 0...100, unit: "%")
                .disabled(l.locks.propertiesLocked)
            Text(l.effects.enabled && l.effects.hasAny
                 ? "Fill fades the layer's own pixels but not its effects (with Blend Interior Effects as Group it fades the inner effects too). Opacity fades everything."
                 : "Fill fades the layer's own pixels but not its effects; Opacity fades both. This layer has no effects, so the two look the same.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Channels:").foregroundStyle(Theme.textDim)
                Toggle2(label: "R", on: lb.channelR)
                Toggle2(label: "G", on: lb.channelG)
                Toggle2(label: "B", on: lb.channelB)
            }
            Picker("Knockout", selection: lb.knockout) { ForEach(Knockout.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 220)
            Toggle2(label: "Blend Interior Effects as Group", on: lb.blendInteriorEffectsAsGroup)
            Toggle2(label: "Blend Clipped Layers as Group", on: lb.blendClippedAsGroup)
            Toggle2(label: "Layer Mask Hides Effects", on: lb.layerMaskHidesEffects)
            Toggle2(label: "Vector Mask Hides Effects", on: lb.vectorMaskHidesEffects)
            Toggle2(label: "Layer effects enabled", on: Binding(get: { lb.wrappedValue.effects.enabled }, set: { lb.wrappedValue.effects.enabled = $0 }))
            Toggle2(label: "Clip to layer below", on: lb.isClipped)
            Caption("Blend If")
            Picker("", selection: lb.blendIf.channel) { ForEach(BlendIfChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100)
            Text("This Layer:").foregroundStyle(Theme.textDim)
            BlendIfSlider(low: lb.blendIf.thisLow, high: lb.blendIf.thisHigh, channel: lb.wrappedValue.blendIf.channel)
            Text("Underlying Layer:").foregroundStyle(Theme.textDim)
            BlendIfSlider(low: lb.blendIf.underLow, high: lb.blendIf.underHigh, channel: lb.wrappedValue.blendIf.channel)
            Text("⌥-drag a slider to split it for a smooth transition.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }

    func modeRow(_ mode: Binding<BlendMode>, color: Binding<RGBA>?) -> some View {
        HStack {
            Text("Blend Mode").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
            BlendModePicker(mode: mode)
            if let c = color { ColorWell(color: c, size: 18) }
        }
    }

    func pct(_ label: String, _ v: Binding<Double>) -> some View {
        ValueSlider(label: label, value: Binding(get: { v.wrappedValue * 100 }, set: { v.wrappedValue = $0 / 100 }), range: 0...100, unit: "%")
    }

    /// Angle control; when "Use Global Light" is on it edits the document's global light (like Photoshop).
    @ViewBuilder func angleRow(_ a: Binding<Double>, global: Binding<Bool>? = nil) -> some View {
        let useGlobal = global?.wrappedValue ?? false
        let b: Binding<Double> = useGlobal
            ? Binding(get: { doc?.state.globalLight.angle ?? 120 }, set: { v in doc?.state.globalLight.angle = v })
            : a
        HStack {
            Text("Angle").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
            AngleDial(angle: b)
            NumberField(label: "", value: b, width: 40)
            Text("°").foregroundStyle(Theme.textFaint)
            if let g = global { Toggle2(label: "Use Global Light", on: g) }
        }
    }

    func contourRow(_ label: String, _ c: Binding<Contour>) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
            ContourPicker(contour: c)
            Toggle2(label: "Anti-aliased", on: c.antialias)
        }
    }

    @ViewBuilder func shadowView(_ s: Binding<ShadowEffect>, inner: Bool) -> some View {
        Caption(inner ? "Inner Shadow — Structure" : "Drop Shadow — Structure")
        modeRow(s.blendMode, color: s.color)
        pct("Opacity", s.opacity)
        angleRow(s.angle, global: s.useGlobalLight)
        ValueSlider(label: "Distance", value: s.distance, range: 0...300, unit: "px")
        ValueSlider(label: inner ? "Choke" : "Spread", value: s.spread, range: 0...100, unit: "%")
        ValueSlider(label: "Size", value: s.size, range: 0...250, unit: "px")
        Caption("Quality")
        contourRow("Contour", s.contour)
        ValueSlider(label: "Noise", value: s.noise, range: 0...100, unit: "%")
        if !inner { Toggle2(label: "Layer Knocks Out Drop Shadow", on: s.layerKnocksOut) }
    }

    @ViewBuilder func glowView(_ g: Binding<GlowEffect>, inner: Bool) -> some View {
        Caption(inner ? "Inner Glow — Structure" : "Outer Glow — Structure")
        modeRow(g.blendMode, color: nil)
        pct("Opacity", g.opacity)
        ValueSlider(label: "Noise", value: g.noise, range: 0...100, unit: "%")
        HStack {
            Picker("", selection: g.useGradient) { Text("Color").tag(false); Text("Gradient").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            if g.wrappedValue.useGradient {
                GradientSwatch(gradient: g.wrappedValue.gradient).frame(width: 90, height: 18)
            } else {
                ColorWell(color: g.color, size: 18)
            }
        }
        if g.wrappedValue.useGradient { GradientStopsEditor(gradient: g.gradient) }
        Caption("Elements")
        Picker("Technique", selection: g.technique) { Text("Softer").tag(GlowTechnique.softer); Text("Precise").tag(GlowTechnique.precise) }.pickerStyle(.segmented)
        if inner {
            Picker("Source", selection: g.source) { Text("Center").tag(GlowSource.center); Text("Edge").tag(GlowSource.edge) }.pickerStyle(.segmented)
        }
        ValueSlider(label: inner ? "Choke" : "Spread", value: g.spread, range: 0...100, unit: "%")
        ValueSlider(label: "Size", value: g.size, range: 0...250, unit: "px")
        Caption("Quality")
        contourRow("Contour", g.contour)
        ValueSlider(label: "Range", value: g.range, range: 1...100, unit: "%")
        ValueSlider(label: "Jitter", value: g.jitter, range: 0...100, unit: "%")
    }

    @ViewBuilder func bevelView(_ b: Binding<BevelEffect>) -> some View {
        Caption("Structure")
        Picker("Style", selection: b.style) { ForEach(BevelStyle.allCases, id: \.self) { Text($0.displayName).tag($0) } }
        Picker("Technique", selection: b.technique) { ForEach(BevelTechnique.allCases, id: \.self) { Text($0.displayName).tag($0) } }
        ValueSlider(label: "Depth", value: b.depth, range: 1...1000, unit: "%")
        Picker("Direction", selection: b.directionUp) { Text("Up").tag(true); Text("Down").tag(false) }.pickerStyle(.segmented)
        ValueSlider(label: "Size", value: b.size, range: 0...250, unit: "px")
        ValueSlider(label: "Soften", value: b.soften, range: 0...16, unit: "px")
        Caption("Shading")
        angleRow(b.angle, global: b.useGlobalLight)
        if b.wrappedValue.useGlobalLight {
            ValueSlider(label: "Altitude", value: Binding(get: { doc?.state.globalLight.altitude ?? 30 }, set: { v in doc?.state.globalLight.altitude = v }), range: 0...90, unit: "°")
        } else {
            ValueSlider(label: "Altitude", value: b.altitude, range: 0...90, unit: "°")
        }
        contourRow("Gloss Contour", b.glossContour)
        HStack {
            Text("Highlight").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
            BlendModePicker(mode: b.highlightMode, width: 100)
            ColorWell(color: b.highlightColor, size: 18)
        }
        pct("Opacity", b.highlightOpacity)
        HStack {
            Text("Shadow").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
            BlendModePicker(mode: b.shadowMode, width: 100)
            ColorWell(color: b.shadowColor, size: 18)
        }
        pct("Opacity", b.shadowOpacity)
        Divider()
        Toggle2(label: "Contour", on: b.contourEnabled)
        if b.wrappedValue.contourEnabled {
            contourRow("Contour", b.contour)
            ValueSlider(label: "Range", value: b.contourRange, range: 1...100, unit: "%")
        }
        Toggle2(label: "Texture", on: b.textureEnabled)
        if b.wrappedValue.textureEnabled {
            HStack {
                Text("Pattern").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
                PatternPicker(patternID: b.texturePatternID)
                Toggle2(label: "Invert", on: b.textureInvert)
            }
            ValueSlider(label: "Scale", value: Binding(get: { b.wrappedValue.textureScale * 100 }, set: { b.wrappedValue.textureScale = $0 / 100 }), range: 1...1000, unit: "%")
            ValueSlider(label: "Depth", value: b.textureDepth, range: -1000...1000, unit: "%")
        }
    }

    @ViewBuilder func satinView(_ s: Binding<SatinEffect>) -> some View {
        Caption("Satin")
        modeRow(s.blendMode, color: s.color)
        pct("Opacity", s.opacity)
        angleRow(s.angle)
        ValueSlider(label: "Distance", value: s.distance, range: 1...250, unit: "px")
        ValueSlider(label: "Size", value: s.size, range: 0...250, unit: "px")
        contourRow("Contour", s.contour)
        Toggle2(label: "Invert", on: s.invert)
    }

    @ViewBuilder func strokeView(_ s: Binding<StrokeEffect>) -> some View {
        Caption("Structure")
        ValueSlider(label: "Size", value: s.size, range: 1...250, unit: "px")
        Picker("Position", selection: s.position) { ForEach(StrokePosition.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented)
        modeRow(s.blendMode, color: nil)
        pct("Opacity", s.opacity)
        Caption("Fill Type")
        PaintStyleEditor(paint: s.paint)
    }
}

// MARK: - Contour picker

struct ContourThumb: View {
    let contour: Contour
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let p = contour.previewPath(size: size)
            var fill = Path(p)
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .color(Color(white: 0.2)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.45), lineWidth: 0.5))
    }
}

struct ContourPicker: View {
    @Binding var contour: Contour
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                ContourThumb(contour: contour).frame(width: 26, height: 22)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 6), spacing: 6) {
                    ForEach(ContourPreset.allCases.filter { $0 != .custom }) { p in
                        ContourThumb(contour: Contour(preset: p)).frame(width: 40, height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(contour.preset == p ? Theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { contour.preset = p }
                            .help(p.displayName)
                    }
                }
                Caption("Custom")
                CurveEditor(curve: Binding(get: { contour.preset == .custom ? contour.custom : CurvePoints(points: (0...8).map { CGPoint(x: Double($0) / 8, y: contour.value(Double($0) / 8)) }) },
                                           set: { contour.custom = $0; contour.preset = .custom }),
                            hist: nil, channel: 0, color: .white, onCommit: {})
                    .frame(width: 200, height: 200)
            }
            .padding(10)
        }
    }
}

// MARK: - Blend If slider

struct BlendIfSlider: View {
    @Binding var low: [Double]
    @Binding var high: [Double]
    var channel: BlendIfChannel

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.black, endColor], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                knob(low, 0, w, dark: true)
                knob(low, 1, w, dark: true)
                knob(high, 0, w, dark: false)
                knob(high, 1, w, dark: false)
            }
            .coordinateSpace(name: "blendIf")
        }
        .frame(height: 24)
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(low[0]))\(low[0] != low[1] ? "/\(Int(low[1]))" : "")   \(Int(high[0]))\(high[0] != high[1] ? "/\(Int(high[1]))" : "")")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).offset(y: 14)
        }
        .padding(.bottom, 12)
    }

    var endColor: Color {
        switch channel { case .gray: return .white; case .red: return .red; case .green: return .green; case .blue: return .blue }
    }

    @ViewBuilder func knob(_ vals: [Double], _ idx: Int, _ w: CGFloat, dark: Bool) -> some View {
        let x = CGFloat(vals[idx] / 255) * w
        Path { p in p.move(to: CGPoint(x: 5, y: 0)); p.addLine(to: CGPoint(x: 10, y: 9)); p.addLine(to: CGPoint(x: 0, y: 9)); p.closeSubpath() }
            .fill(dark ? Color.black : Color.white)
            .overlay(Path { p in p.move(to: CGPoint(x: 5, y: 0)); p.addLine(to: CGPoint(x: 10, y: 9)); p.addLine(to: CGPoint(x: 0, y: 9)); p.closeSubpath() }.stroke(Color.gray, lineWidth: 0.5))
            .frame(width: 10, height: 9)
            .offset(x: x - 5, y: 12)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("blendIf")).onChanged { v in
                let nv = clamp(Double(v.location.x / w * 255).rounded(), 0, 255)
                let split = NSEvent.modifierFlags.contains(.option)
                if dark {
                    var l = low
                    if split { l[idx] = nv } else { l = [nv, nv] }
                    l[0] = min(l[0], l[1]); l[1] = min(max(l[1], l[0]), high[0])
                    low = l
                } else {
                    var h = high
                    if split { h[idx] = nv } else { h = [nv, nv] }
                    h[1] = max(h[0], h[1]); h[0] = max(min(h[0], h[1]), low[1])
                    high = h
                }
            })
    }
}
