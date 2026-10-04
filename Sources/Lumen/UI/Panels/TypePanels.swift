import SwiftUI
import ImageCratCore

// MARK: - Type editing helpers (routing panel edits to the selection or the whole layer)

enum TypeEdit {
    static func copyCharacterFields(from s: TextContent, to d: inout TextContent) {
        d.fontName = s.fontName; d.fontSize = s.fontSize; d.color = s.color; d.tracking = s.tracking
        d.baselineShift = s.baselineShift; d.fauxBold = s.fauxBold; d.fauxItalic = s.fauxItalic
        d.underline = s.underline; d.strikethrough = s.strikethrough
        d.horizontalScale = s.horizontalScale; d.verticalScale = s.verticalScale; d.features = s.features
        d.variations = s.variations
    }

    /// Copies everything except the character fields, the text and the runs.
    static func copyNonCharacterFields(from s: TextContent, to d: inout TextContent) {
        var r = s
        copyCharacterFields(from: d, to: &r)
        r.text = d.text; r.runs = d.runs
        d = r
    }

    /// Layer-wide edit: changed character fields become the new defaults (and are cleared from runs).
    static func layerWide(old: TextContent, shown: TextContent, edited: TextContent) -> TextContent {
        let change = CharacterStyle.diff(shown, edited)
        var r = old
        copyNonCharacterFields(from: edited, to: &r)
        if !change.isEmpty { r.applyLayerWide(change) }
        return r
    }

    /// Settings shown for a (non-edited) layer: the style of its first character.
    static func shown(_ t: TextContent) -> TextContent { t.applying(t.style(at: 0)) }

    struct Target {
        var binding: Binding<TextContent>
        var commit: () -> Void
        var editing: Bool
        var hasSelection: Bool
    }

    /// Binding for the active text layer: the on-canvas editor's selection while editing, otherwise the whole layer.
    static func target(doc d: Document, id: UUID) -> Target? {
        _ = TypeEditState.shared.tick
        guard let t = d.state.layer(id)?.text else { return nil }
        if let tool = TextTool.editing, tool.isEditing(id), let shown = tool.shownContent {
            let b = Binding<TextContent>(get: { tool.shownContent ?? shown }, set: { v in
                if let cur = tool.shownContent { tool.applyEdit(from: cur, to: v) }
            })
            return Target(binding: b, commit: {}, editing: true, hasSelection: tool.selectedRange.length > 0)
        }
        let shownT = shown(t)
        let b = Binding<TextContent>(get: { shownT }, set: { v in
            guard let cur = d.state.layer(id)?.text else { return }
            let nt = layerWide(old: cur, shown: shown(cur), edited: v)
            d.updateLayer(id) { $0.text = nt }
            d.setNeedsRender()
        })
        return Target(binding: b, commit: { d.commit("Edit Type") }, editing: false, hasSelection: false)
    }

    /// For the options bar: applies `body` to the selection while editing, else to the active type layer (committed).
    static func update(_ body: (inout TextContent) -> Void) {
        guard let d = AppActions.doc, let id = d.activeLayerID, d.state.layer(id)?.text != nil, let tg = target(doc: d, id: id) else { return }
        var v = tg.binding.wrappedValue
        body(&v)
        tg.binding.wrappedValue = v
        tg.commit()
    }

    static var activeTextLayer: (Document, UUID, TextContent)? {
        guard let d = AppActions.doc, let id = d.activeLayerID, let t = d.state.layer(id)?.text else { return nil }
        return (d, id, t)
    }

    /// Type ▸ Orientation: switches horizontal ↔ vertical, keeping the text roughly in place.
    static func toggleOrientation() {
        if AppModel.shared.textEditingActive { AppActions.canvas?.commitCurrentTool() }
        guard let (d, id, t) = activeTextLayer, t.pathText == nil else { return }
        var n = t
        let r = TextRenderer.localRect(t)
        n.orientation = t.orientation == .horizontal ? .vertical : .horizontal
        if t.boxSize == nil {
            if n.orientation == .vertical {
                // top-left anchored → top-right anchored
                n.position.x = t.position.x + CGFloat(t.fontSize * 0.6 * t.horizontalScale)
            } else {
                n.position.x = t.position.x + r.minX * CGFloat(t.horizontalScale)
            }
        }
        d.updateLayer(id) { $0.text = n }
        d.commit(n.orientation == .vertical ? "Vertical Type" : "Horizontal Type")
        d.setNeedsRender()
    }

    static func openWarpDialog() {
        if AppModel.shared.textEditingActive { AppActions.canvas?.commitCurrentTool() }
        guard activeTextLayer != nil else { AppModel.shared.setStatus("Select a type layer to warp"); return }
        AppModel.shared.dialog = .warpText
    }

    /// Type on a path: flips the text to the other side of the path.
    static func flipPathText() {
        guard let (d, id, t) = activeTextLayer, var p = t.pathText else { return }
        let total = PathSampler(p.path).total
        p.flipped.toggle()
        p.startOffset = Double(total) - p.startOffset
        d.updateLayer(id) { $0.text?.pathText = p }
        d.commit("Flip Type")
        d.setNeedsRender()
    }
}

// MARK: - Character controls

struct CharacterControls: View {
    @Binding var t: TextContent
    var onCommit: () -> Void
    var showOpenType = true

    var body: some View {
        FontPicker(fontName: Binding(get: { t.fontName }, set: { t.fontName = $0; onCommit() }), wraps: true)
        VariableAxesControls(t: $t, onCommit: onCommit)
        ValueSlider(label: "Size", value: $t.fontSize, range: 1...1000, unit: "px", format: "%.1f", onCommit: onCommit)
        WrappingHStack(spacing: 6) {   // (Auto wraps under the slider in a narrow column)
            ValueSlider(label: "Leading", value: Binding(get: { t.leading ?? t.fontSize * 1.2 }, set: { t.leading = $0 }), range: 1...1000, unit: "px", format: "%.1f", onCommit: onCommit)
            Toggle2(label: "Auto", on: Binding(get: { t.leading == nil }, set: { t.leading = $0 ? nil : t.fontSize * 1.2; onCommit() }))
        }
        ValueSlider(label: "Tracking", value: $t.tracking, range: -200...1000, onCommit: onCommit)
        HStack {
            Text("Color").foregroundStyle(Theme.textDim)
            ColorWell(color: $t.color, size: 18, onCommit: onCommit)
            Spacer()
            Toggle2(label: "Anti-alias", on: Binding(get: { t.antialias }, set: { t.antialias = $0; onCommit() }))
        }
        HStack(spacing: 2) {
            IconButton(symbol: "bold", help: "Faux Bold", active: t.fauxBold) { t.fauxBold.toggle(); onCommit() }
            IconButton(symbol: "italic", help: "Faux Italic", active: t.fauxItalic) { t.fauxItalic.toggle(); onCommit() }
            IconButton(symbol: "underline", help: "Underline", active: t.underline) { t.underline.toggle(); onCommit() }
            IconButton(symbol: "strikethrough", help: "Strikethrough", active: t.strikethrough) { t.strikethrough.toggle(); onCommit() }
            IconButton(symbol: "textformat.size.larger", help: "All Caps", active: t.allCaps) { t.allCaps.toggle(); onCommit() }
        }
        ValueSlider(label: "H. Scale", value: Binding(get: { t.horizontalScale * 100 }, set: { t.horizontalScale = max(0.01, $0 / 100) }), range: 10...400, unit: "%", onCommit: onCommit)
        ValueSlider(label: "V. Scale", value: Binding(get: { t.verticalScale * 100 }, set: { t.verticalScale = max(0.01, $0 / 100) }), range: 10...400, unit: "%", onCommit: onCommit)
        ValueSlider(label: "Baseline", value: $t.baselineShift, range: -200...200, unit: "px", onCommit: onCommit)
        if showOpenType { OpenTypeControls(features: $t.features, onCommit: onCommit) }
    }
}

struct FeatureToggle: View {
    let label: String
    let help: String
    var italic = false
    @Binding var on: Bool
    var onCommit: () -> Void
    @State private var hovering = false
    var body: some View {
        Button { on.toggle(); onCommit() } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .serif))
                .italic(italic)
                .frame(minWidth: 24, minHeight: 22)
                .padding(.horizontal, 2)
                .foregroundStyle(on ? Color.white : Theme.text)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.accent.opacity(0.8) : (hovering ? Theme.hover : Theme.fieldBG)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct OpenTypeControls: View {
    @Binding var features: OpenTypeFeatures
    var onCommit: () -> Void
    var body: some View {
        Caption("OpenType")
        WrappingHStack(spacing: 3, lineSpacing: 3) {
            FeatureToggle(label: "fi", help: "Standard Ligatures", on: $features.standardLigatures, onCommit: onCommit)
            FeatureToggle(label: "st", help: "Discretionary Ligatures", italic: true, on: $features.discretionaryLigatures, onCommit: onCommit)
            FeatureToggle(label: "𝒜", help: "Swash", on: $features.swash, onCommit: onCommit)
            FeatureToggle(label: "aa", help: "Stylistic Alternates", on: $features.stylisticAlternates, onCommit: onCommit)
            FeatureToggle(label: "1st", help: "Ordinals", on: $features.ordinals, onCommit: onCommit)
            FeatureToggle(label: "½", help: "Fractions", on: $features.fractions, onCommit: onCommit)
            FeatureToggle(label: "Tᴛ", help: "Small Caps", on: $features.smallCaps, onCommit: onCommit)
            FeatureToggle(label: "123", help: "Oldstyle Figures", on: $features.oldStyleFigures, onCommit: onCommit)
        }
    }
}

// MARK: - Paragraph controls

struct ParagraphControls: View {
    @Binding var t: TextContent
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TextAlign.paragraphCases, id: \.self) { a in
                IconButton(symbol: a.symbol, help: a.displayName, active: t.alignment == a) { t.alignment = a; onCommit() }
                    .overlay(alignment: .bottom) {
                        if a == .justifyCenter || a == .justifyAll {
                            Text(a == .justifyCenter ? "c" : "a").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textFaint).offset(y: 3)
                        }
                    }
            }
        }
        ValueSlider(label: "Indent Left", value: $t.leftIndent, range: -500...500, unit: "px", onCommit: onCommit)
        ValueSlider(label: "Indent Right", value: $t.rightIndent, range: -500...500, unit: "px", onCommit: onCommit)
        ValueSlider(label: "First Line", value: $t.firstLineIndent, range: -500...500, unit: "px", onCommit: onCommit)
        ValueSlider(label: "Space Before", value: $t.spaceBefore, range: 0...500, unit: "px", onCommit: onCommit)
        ValueSlider(label: "Space After", value: $t.spaceAfter, range: 0...500, unit: "px", onCommit: onCommit)
        Toggle2(label: "Hyphenate", on: Binding(get: { t.hyphenate }, set: { t.hyphenate = $0; onCommit() }))
        ParagraphExtrasControls(t: $t, onCommit: onCommit)
    }
}

/// Orientation, warp and path options shared by the Properties panel and the options bar.
struct TypeLayoutButtons: View {
    let t: TextContent
    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: t.orientation == .vertical ? "text.alignleft" : "character.textbox", help: "Toggle Text Orientation") { TypeEdit.toggleOrientation() }
                .disabled(t.pathText != nil)
            IconButton(symbol: "water.waves", help: "Warp Text…", active: t.warp.map { !$0.isIdentity } ?? false) { TypeEdit.openWarpDialog() }
            if t.pathText != nil {
                IconButton(symbol: "arrow.up.arrow.down", help: "Flip Type on Path") { TypeEdit.flipPathText() }
            }
        }
    }
}

// MARK: - Properties panel section (replaces the old TextProperties)

struct TextProperties: View {
    @Binding var t: TextContent
    var onCommit: () -> Void

    var body: some View {
        let _ = TypeEditState.shared.tick
        if let (d, id, _) = TypeEdit.activeTextLayer, let tg = TypeEdit.target(doc: d, id: id) {
            content(tg.binding, tg.commit, tg)
        } else {
            let old = t
            content(Binding(get: { TypeEdit.shown(old) }, set: { v in t = TypeEdit.layerWide(old: old, shown: TypeEdit.shown(old), edited: v) }), onCommit, nil)
        }
    }

    @ViewBuilder func content(_ b: Binding<TextContent>, _ commit: @escaping () -> Void, _ tg: TypeEdit.Target?) -> some View {
        HStack {
            Caption("Character")
            Spacer()
            if let tg, tg.editing { Text(tg.hasSelection ? "Selection" : "Typing").font(Theme.fontSmall).foregroundStyle(Theme.accent) }
        }
        CharacterControls(t: b, onCommit: commit)
        Caption("Paragraph")
        ParagraphControls(t: b, onCommit: commit)
        HStack {
            TypeLayoutButtons(t: b.wrappedValue)
            Spacer()
        }
        WrappingHStack {
            Button("Convert to Shape") { AppActions.convertTextToShape() }.buttonStyle(PanelButtonStyle())
            Button("Work Path") { AppActions.createWorkPathFromText() }.buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - Character / Paragraph panels

struct CharacterPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let _ = TypeEditState.shared.tick
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let d = app.activeDocument, let id = d.activeLayerID, d.state.layer(id)?.text != nil, let tg = TypeEdit.target(doc: d, id: id) {
                    HStack {
                        Caption(tg.editing ? (tg.hasSelection ? "Selected Characters" : "Typing Style") : "Whole Layer")
                        Spacer()
                    }
                    CharacterControls(t: tg.binding, onCommit: tg.commit)
                } else {
                    Caption("Type Tool Defaults")
                    FontPicker(fontName: $app.textTool.fontName, wraps: true)
                    ValueSlider(label: "Size", value: $app.textTool.fontSize, range: 1...1000, unit: "px")
                    Text("Select a type layer to edit its character settings.").foregroundStyle(Theme.textFaint)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font)
    }
}

struct ParagraphPanel: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let _ = TypeEditState.shared.tick
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let d = app.activeDocument, let id = d.activeLayerID, d.state.layer(id)?.text != nil, let tg = TypeEdit.target(doc: d, id: id) {
                    ParagraphControls(t: tg.binding, onCommit: tg.commit)
                    HStack { TypeLayoutButtons(t: tg.binding.wrappedValue); Spacer() }
                } else {
                    Caption("Type Tool Defaults")
                    HStack(spacing: 2) {
                        ForEach(TextAlign.allCases, id: \.self) { a in
                            IconButton(symbol: a.symbol, help: a.displayName, active: app.textTool.alignment == a) { app.textTool.alignment = a }
                        }
                    }
                    Text("Select a type layer to edit its paragraph settings.").foregroundStyle(Theme.textFaint)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font)
    }
}

// MARK: - Options bar extras (text tool)

struct TextOptionsExtras: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let _ = TypeEditState.shared.tick
        if let t = app.activeDocument?.activeLayer?.text {
            TypeLayoutButtons(t: t)
        } else {
            IconButton(symbol: "water.waves", help: "Warp Text… (select a type layer)") { TypeEdit.openWarpDialog() }
        }
    }
}

// MARK: - Warp Text dialog

struct WarpTextDialog: View {
    @State private var warp: TextWarp
    // (@State: SwiftUI re-creates this view whenever the previewed document changes, so a plain `let` captured in
    // init would pick up the preview itself as the "original")
    @State private var layerID: UUID?

    init() {
        let a = TypeEdit.activeTextLayer
        _layerID = State(initialValue: a?.1)
        var w = a?.2.warp ?? TextWarp(style: .none, bend: 50)
        if a?.2.warp == nil { w.style = .none }
        _warp = State(initialValue: w)
    }

    /// Live preview: changes the layer without recording a history step.
    static func preview(_ d: Document, _ id: UUID, _ w: TextWarp) {
        d.updateLayer(id) { $0.text?.warp = w.style == .none ? nil : w }
        d.setNeedsRender()
    }

    /// Cancel: back to the warp of the last recorded state (whatever was previewed in between).
    static func cancel(_ d: Document, _ id: UUID) {
        let original = d.committedState.layer(id)?.text?.warp
        d.updateLayer(id) { $0.text?.warp = original }
        d.setNeedsRender()
    }

    /// OK: one "Warp Text" step, only when the warp differs from the recorded one.
    static func commit(_ d: Document, _ id: UUID, _ w: TextWarp) {
        preview(d, id, w)
        if d.state.layer(id)?.text?.warp != d.committedState.layer(id)?.text?.warp { d.commit("Warp Text") }
    }

    var body: some View {
        DialogFrame(title: "Warp Text", width: 340, onOK: {
            guard let d = AppActions.doc, let id = layerID else { return }
            WarpTextDialog.commit(d, id, warp)
        }, onCancel: {
            guard let d = AppActions.doc, let id = layerID else { return }
            WarpTextDialog.cancel(d, id)
        }) {
            if layerID == nil {
                Text("Select a type layer first.").foregroundStyle(Theme.textFaint)
            }
            HStack {
                Text("Style").foregroundStyle(Theme.textDim).frame(width: 78, alignment: .leading)
                Picker("", selection: $warp.style) {
                    ForEach(WarpStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            ValueSlider(label: "Bend", value: $warp.bend, range: -100...100, unit: "%")
            ValueSlider(label: "Horizontal", value: $warp.horizontalDistortion, range: -100...100, unit: "%")
            ValueSlider(label: "Vertical", value: $warp.verticalDistortion, range: -100...100, unit: "%")
                .disabled(warp.style == .none)
        }
        .onChange(of: warp) { _, w in
            guard let d = AppActions.doc, let id = layerID else { return }
            WarpTextDialog.preview(d, id, w)
        }
    }
}
