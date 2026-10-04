import SwiftUI
import ImageCratCore

// Character / Paragraph panel sections for variable fonts, lists, area type, Dynamic Text and the world-ready composer.

// MARK: - Variable font axes (Character panel)

struct VariableAxesControls: View {
    @Binding var t: TextContent
    var onCommit: () -> Void

    var body: some View {
        let axes = FontAxis.axes(fontName: t.fontName).filter { !$0.hidden }
        if !axes.isEmpty {
            HStack {
                Caption("Variable Font")
                Spacer()
                if !t.variations.isEmpty {
                    Button("Reset") { t.variations = [:]; onCommit() }.buttonStyle(.plain).font(Theme.fontSmall).foregroundStyle(Theme.accent)
                }
            }
            ForEach(axes) { a in
                let fine = a.max - a.min <= 10
                ValueSlider(label: a.name, value: Binding(get: {
                    t.variations[a.tag] ?? FontAxis.currentValue(fontName: t.fontName, tag: a.tag) ?? a.defaultValue
                }, set: { v in
                    var vars = t.variations
                    vars[a.tag] = v
                    t.variations = vars
                }), range: safeRange(a.min, a.max), format: fine ? "%.2f" : "%.0f", onCommit: onCommit)
                .help("\(a.name) (\(a.tag)) \(fine ? String(format: "%.2f–%.2f", a.min, a.max) : String(format: "%.0f–%.0f", a.min, a.max))")
            }
        }
    }
}

// MARK: - Paragraph extras

struct ParagraphExtrasControls: View {
    @Binding var t: TextContent
    var onCommit: () -> Void

    var body: some View {
        ListControls(t: $t, onCommit: onCommit)
        if t.area != nil || t.boxSize != nil {
            DynamicTextControls(t: $t, onCommit: onCommit)
        }
        if let a = t.area {
            Caption("Area Type")
            ValueSlider(label: "Inset", value: Binding(get: { a.inset }, set: { v in t.area?.inset = v }), range: 0...200, unit: "px", onCommit: onCommit)
        }
        ComposerControls(t: $t, onCommit: onCommit)
    }
}

struct ListControls: View {
    @Binding var t: TextContent
    var onCommit: () -> Void

    private enum Mode: String, CaseIterable { case none = "None", bullets = "Bullets", numbers = "Numbers" }

    var body: some View {
        Caption("Lists")
        let mode: Mode = t.list == nil ? .none : (t.list!.kind == .bullet ? .bullets : .numbers)
        Picker("", selection: Binding(get: { mode }, set: { m in
            switch m {
            case .none: t.list = nil
            case .bullets: var l = t.list ?? TextListStyle(); l.kind = .bullet; t.list = l
            case .numbers: var l = t.list ?? TextListStyle(); l.kind = .numbered; t.list = l
            }
            onCommit()
        })) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .segmentedOrMenu()
        if let l = t.list {
            if l.kind == .bullet {
                WrappingHStack {
                    Text("Bullet").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
                    Picker("", selection: Binding(get: { l.bullet }, set: { t.list?.bullet = $0; onCommit() })) {
                        ForEach(BulletGlyph.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    if l.bullet == .custom {
                        TextField("", text: Binding(get: { l.customGlyph }, set: { t.list?.customGlyph = String($0.prefix(4)) }))
                            .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 40)
                            .onSubmit(onCommit)
                    }
                }
            } else {
                WrappingHStack {
                    Text("Style").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
                    Picker("", selection: Binding(get: { l.numbering }, set: { t.list?.numbering = $0; onCommit() })) {
                        ForEach(NumberingStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    Picker("", selection: Binding(get: { l.suffix }, set: { t.list?.suffix = $0; onCommit() })) {
                        ForEach([".", ")", ":", ""], id: \.self) { Text($0.isEmpty ? "none" : $0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 56)
                }
                ValueSlider(label: "Start At", value: Binding(get: { Double(l.start) }, set: { t.list?.start = max(0, Int($0.rounded())) }),
                            range: 0...999, step: 1, onCommit: onCommit)
            }
            WrappingHStack(spacing: 6) {
                ValueSlider(label: "Hanging", value: Binding(get: { l.hangingIndent ?? t.fontSize * 1.2 }, set: { t.list?.hangingIndent = $0 }),
                            range: 0...500, unit: "px", onCommit: onCommit)
                Toggle2(label: "Auto", on: Binding(get: { l.hangingIndent == nil }, set: { t.list?.hangingIndent = $0 ? nil : t.fontSize * 1.2; onCommit() }))
            }
            WrappingHStack {
                Text("Marker Color").foregroundStyle(Theme.textDim)
                ColorWell(color: Binding(get: { l.markerColor ?? t.color }, set: { t.list?.markerColor = $0 }), size: 16, onCommit: onCommit)
                if l.markerColor != nil {
                    Button("Text Color") { t.list?.markerColor = nil; onCommit() }.buttonStyle(.plain).font(Theme.fontSmall).foregroundStyle(Theme.accent)
                }
                Spacer()
            }
        }
    }
}

struct DynamicTextControls: View {
    @Binding var t: TextContent
    var onCommit: () -> Void

    var body: some View {
        Caption("Dynamic Text")
        WrappingHStack {
            Toggle2(label: t.area != nil ? "Fit to Shape" : "Fit to Box", on: Binding(get: { t.fitToBox != nil }, set: { t.fitToBox = $0 ? TextFit() : nil; onCommit() }))
            if t.fitToBox != nil {
                Toggle2(label: "Adjust Tracking", on: Binding(get: { t.fitToBox?.adjustTracking ?? false }, set: { t.fitToBox?.adjustTracking = $0; onCommit() }))
            }
            Spacer()
        }
        if t.fitToBox != nil, let info = TextRenderer.fitInfo(t) {
            Text(String(format: "Fitted size %.1f px", t.fontSize * Double(info.scale)) + (info.tracking > 0.5 ? String(format: ", tracking +%.0f", info.tracking) : ""))
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

struct ComposerControls: View {
    @Binding var t: TextContent
    var onCommit: () -> Void

    var body: some View {
        Caption("Composer")
        HStack {
            Picker("", selection: Binding(get: { t.composer }, set: { t.composer = $0; onCommit() })) {
                ForEach(TextComposer.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
        }
        if t.composer == .worldReady {
            HStack(spacing: 2) {
                Text("Direction").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
                IconButton(symbol: "arrow.left.and.right.text.vertical", help: "Auto (first strong character)", active: t.direction == .auto) { t.direction = .auto; onCommit() }
                IconButton(symbol: "text.alignleft", help: "Left-to-Right Text Direction", active: t.direction == .ltr) { setDirection(.ltr) }
                IconButton(symbol: "text.alignright", help: "Right-to-Left Text Direction", active: t.direction == .rtl) { setDirection(.rtl) }
                Spacer()
            }
        }
    }

    private func setDirection(_ d: TextDirection) {
        // Photoshop flips the natural alignment together with the direction.
        if d == .rtl && t.alignment == .left { t.alignment = .right }
        if d == .ltr && t.alignment == .right && t.direction == .rtl { t.alignment = .left }
        t.direction = d
        onCommit()
    }
}

// MARK: - Menu actions

enum TypeActions2 {
    /// Applies a layer-level (paragraph) change to the active type layer, through the editor when it is open.
    static func updateParagraph(_ name: String, _ body: (inout TextContent) -> Void) {
        guard let (d, id, t) = TypeEdit.activeTextLayer else { AppModel.shared.setStatus("Select a type layer first."); return }
        if let tool = TextTool.editing, tool.isEditing(id) {
            TypeEdit.update(body)   // paragraph fields go to the edited layer; committed with the edit session
        } else {
            var n = t
            body(&n)
            guard n != t else { return }
            d.updateLayer(id) { $0.text = n }
            d.commit(name)
            d.setNeedsRender()
        }
        TypeEditState.shared.tick += 1
    }

    static func setList(_ l: TextListStyle?) { updateParagraph(l == nil ? "Remove List" : "List") { $0.list = l } }

    /// Structural conversions commit the editor first.
    static func convert(_ name: String, _ body: (inout TextContent) -> Void) {
        if AppModel.shared.textEditingActive { AppActions.canvas?.commitCurrentTool() }
        guard let (d, id, t) = TypeEdit.activeTextLayer else { AppModel.shared.setStatus("Select a type layer first."); return }
        var n = t
        body(&n)
        guard n != t else { return }
        d.updateLayer(id) { $0.text = n }
        d.commit(name)
        d.setNeedsRender()
        TypeEditState.shared.tick += 1
    }

    static func toggleFit() {
        guard let (_, _, t) = TypeEdit.activeTextLayer else { AppModel.shared.setStatus("Select a type layer first."); return }
        guard t.boxSize != nil || t.area != nil else { AppModel.shared.setStatus("Dynamic Text needs paragraph or area type (Type ▸ Convert to Paragraph Text)."); return }
        let on = t.fitToBox == nil
        updateParagraph(on ? "Fit Text to Box" : "Stop Fitting Text") { $0.fitToBox = on ? TextFit() : nil }
    }

    /// Creates area type inside the active path / shape layer (Type ▸ Create Area Type from Path).
    static func areaFromActivePath() {
        guard let d = AppActions.doc else { return }
        var path: VectorPath? = nil
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }) { path = np.path }
        if path == nil, let s = d.activeLayer?.shape { path = s.path }
        guard let p = path.map({ VectorPath(subpaths: $0.subpaths.filter { $0.closed && $0.points.count >= 3 }) }), !p.isEmpty else {
            AppModel.shared.setStatus("Select a closed path or shape layer first.")
            return
        }
        var base = TextContent()
        let ts = AppModel.shared.textTool
        base.fontName = ts.fontName; base.fontSize = ts.fontSize; base.alignment = ts.alignment; base.color = ts.color ?? AppModel.shared.foreground
        base.text = "Area type flows inside the shape. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
        let t = TextContent.areaText(in: p, base: base)
        let l = Layer(name: "Area Type", content: .text(t))
        d.addLayer(l)
        d.commit("Area Type")
        d.setNeedsRender()
    }
}
