import SwiftUI
import AppKit
import ImageCratCore

/// The fill layer dialogs (Photoshop's Color Picker / Gradient Fill / Pattern Fill): opened for a new fill layer and by
/// double-clicking one. Every change shows on the canvas at once (live edits of the layer); OK makes one history step,
/// Cancel puts everything back — and removes the layer when it was being created. While the dialog is open, dragging in
/// the image moves the gradient or the pattern.
enum FillKind: String, CaseIterable, Identifiable {
    case solid = "Solid Color", gradient = "Gradient", pattern = "Pattern"
    var id: String { rawValue }

    init(_ p: PaintStyle) {
        switch p {
        case .gradient: self = .gradient
        case .pattern: self = .pattern
        default: self = .solid
        }
    }

    /// Layer name / history name stem, as Photoshop names them.
    var layerName: String {
        switch self {
        case .solid: return "Color Fill"
        case .gradient: return "Gradient Fill"
        case .pattern: return "Pattern Fill"
        }
    }
}

struct FillLayerDialog: View {
    static let dialogID = "shapesfills.fillLayer"
    static let samplerToken = "shapesfills.fillDrag"

    final class Session {
        weak var doc: Document?
        let layerID: UUID
        let isNew: Bool
        var dragStart: (point: CGPoint, offset: CGPoint)?
        var monitor: Any?
        init(doc: Document, layerID: UUID, isNew: Bool) { self.doc = doc; self.layerID = layerID; self.isNew = isNew }
    }
    /// The layer the open dialog edits (kept explicitly: the active layer or document may change while it is open).
    static var session: Session?

    static func register() {
        DialogRegistry.register(dialogID, dims: false) { AnyView(FillLayerDialog()) }
    }

    // MARK: Opening

    /// Opens the dialog for an existing fill layer of the active document.
    static func open(_ layerID: UUID) {
        guard let d = AppActions.doc else { return }
        open(d, layerID, isNew: false)
    }

    static func open(_ d: Document, _ layerID: UUID, isNew: Bool) {
        guard let l = d.state.layer(layerID), let f = l.fill, f.recipe == nil else { Beep.play(); return }
        if AppModel.shared.dialog?.id == ActiveDialog.custom(dialogID).id { close() }
        session = Session(doc: d, layerID: layerID, isNew: isNew)
        DialogRegistry.show(dialogID)   // (first: replacing another dialog reverts that dialog's live edits)
        // a pattern tiled the old way gets a placement that keeps it where it is, so dragging or turning it starts from there
        if case .pattern(let id, let scale) = f.paint, f.patternPlacement == nil,
           let p = PatternLibrary.pattern(id: id, custom: AppModel.shared.customPatterns) {
            let th = CGFloat(p.image.height) * CGFloat(max(0.01, scale))
            let oy = (CGFloat(d.state.height) - th).truncatingRemainder(dividingBy: th)
            d.updateLayer(layerID) { $0.fill?.patternPlacement = PatternPlacement(angle: 0, offset: CGPoint(x: 0, y: oy), linked: false) }
        }
        CanvasSampler.shared.arm(samplerToken) { p, _ in beginDrag(at: p) }
        AppModel.shared.setStatus(statusHint(FillKind(f.paint)))
    }

    /// Layer ▸ New Fill Layer: adds the layer (not yet a history step) and opens its dialog.
    static func newLayer(_ kind: FillKind) {
        let app = AppModel.shared
        if app.dialog != nil { app.dialog = nil }
        guard let d = AppActions.doc else { return }
        var placement: PatternPlacement? = nil
        let paint: PaintStyle
        switch kind {
        case .solid: paint = .color(app.foreground)
        case .gradient:
            var g = GradientFill(gradient: .twoColor(app.foreground, app.background))
            g.alignWithLayer = true
            paint = .gradient(g)
        case .pattern:
            paint = .pattern(id: app.customPatterns.last?.id ?? "checker", scale: 1)
            placement = PatternPlacement()
        }
        var l = Layer(name: d.nextLayerName(kind.layerName), content: .fill(FillContent(paint: paint, patternPlacement: placement)))
        if let sel = d.state.selection {
            l.mask = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0)
            d.state.selection = nil
        }
        d.addLayer(l)
        open(d, l.id, isNew: true)
    }

    // MARK: OK / Cancel

    static func ok() {
        FieldEdits.commit()
        if let s = session, let d = s.doc, let f = d.state.layer(s.layerID)?.fill {
            d.commit(s.isNew ? "New \(FillKind(f.paint).layerName) Layer" : "Edit \(FillKind(f.paint).layerName)")
        }
        close()
    }

    static func cancel() {
        FieldEdits.discard()
        session?.doc?.revertUncommitted()
        session?.doc?.setNeedsRender()
        close()
    }

    static func close() {
        endDrag()
        CanvasSampler.shared.disarm(samplerToken)
        session = nil
        if AppModel.shared.dialog?.id == ActiveDialog.custom(dialogID).id { AppModel.shared.dialog = nil }
    }

    // MARK: Editing

    static func edit(_ body: (inout FillContent) -> Void) {
        guard let s = session, let d = s.doc else { return }
        d.updateLayer(s.layerID) { l in
            guard var f = l.fill else { return }
            body(&f)
            l.fill = f
        }
        d.setNeedsRender()
    }

    struct Current { let doc: Document; let layer: Layer; let fill: FillContent }
    static var current: Current? {
        guard let s = session, let d = s.doc, let l = d.state.layer(s.layerID), let f = l.fill else { return nil }
        return Current(doc: d, layer: l, fill: f)
    }

    // MARK: Dragging in the image

    /// Bounds the gradient's offset percentages refer to.
    static func gradientReference(_ g: GradientFill, _ l: Layer, _ d: Document) -> CGRect {
        let canvas = d.state.canvasCGRect
        if g.alignWithLayer == true, let b = PaintRenderer.alignBounds(l, canvas: canvas) { return b }
        return canvas
    }

    static func offset(of f: FillContent) -> CGPoint {
        switch f.paint {
        case .gradient(let g): return g.offset ?? .zero
        case .pattern: return f.patternPlacement?.offset ?? .zero
        default: return .zero
        }
    }

    static func beginDrag(at p: CGPoint) {
        guard let s = session, let f = current?.fill else { return }
        if case .color = f.paint { pickColor(at: p); return }
        endDrag()
        s.dragStart = (p, offset(of: f))
        s.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { e in
            guard let c = AppActions.canvas, e.window === c.window else { return e }
            let v = c.convert(e.locationInWindow, from: nil)
            if e.type == .leftMouseDragged { drag(to: c.viewToDoc(v)) } else { endDrag() }
            return nil
        }
    }

    static func drag(to p: CGPoint) {
        guard let s = session, let start = s.dragStart, let cur = current else { return }
        let d = cur.doc, l = cur.layer, f = cur.fill
        let dx = p.x - start.point.x, dy = p.y - start.point.y
        switch f.paint {
        case .gradient(let g):
            let r = gradientReference(g, l, d)
            let o = CGPoint(x: start.offset.x + dx / max(1, r.width) * 100, y: start.offset.y + dy / max(1, r.height) * 100)
            edit { f in if case .gradient(var g) = f.paint { g.offset = o; f.paint = .gradient(g) } }
        case .pattern:
            edit { f in
                var pl = f.patternPlacement ?? PatternPlacement()
                pl.offset = CGPoint(x: start.offset.x + dx, y: start.offset.y + dy)
                f.patternPlacement = pl
            }
        default: break
        }
    }

    /// Solid Color: a click in the image picks the colour there (of the layers below and around, not of this fill).
    static func pickColor(at p: CGPoint) {
        guard let s = session, let d = s.doc else { return }
        let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
        guard x >= 0, y >= 0, x < d.state.width, y < d.state.height else { return }
        let img = Compositor.shared.composite(d.state, options: Compositor.Options(hidden: [s.layerID]))
        let b = RenderEngine.renderBuffer(img, docRect: IRect(x: x, y: y, width: 1, height: 1), space: CanvasSpace(width: d.state.width, height: d.state.height))
        let (r, g, bl, a) = b.pixel(0, 0)   // (not premultiplied)
        guard a > 0 else { return }
        let c = RGBA(r: Double(r) / 255, g: Double(g) / 255, b: Double(bl) / 255)
        edit { $0.paint = .color(c) }
    }

    static func endDrag() {
        if let m = session?.monitor { NSEvent.removeMonitor(m) }
        session?.monitor = nil
        session?.dragStart = nil
    }

    // MARK: View

    @Bindable private var app = AppModel.shared

    var body: some View {
        if let cur = Self.current {
            let l = cur.layer, f = cur.fill
            let kind = FillKind(f.paint)
            DialogFrame(title: kind == .solid ? "Color Fill" : kind.layerName, width: kind == .solid ? 470 : 440, onOK: Self.ok, onCancel: Self.cancel) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Contents").foregroundStyle(Theme.textDim)
                        Picker("", selection: Binding(get: { kind }, set: { k in Self.change(to: k) })) {
                            ForEach(FillKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                        .help("Layer ▸ Change Layer Content")
                        Spacer()
                        Text(l.name).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                    switch f.paint {
                    case .gradient(let g): GradientFillControls(g: g, layer: l)
                    case .pattern(let id, let scale): PatternFillControls(id: id, scale: scale, placement: f.patternPlacement ?? PatternPlacement())
                    case .color(let c): ColorPickerView(color: Binding(get: { c }, set: { v in Self.edit { $0.paint = .color(v) } }), title: "Pick a solid color", showAlpha: true)
                    case .none: Text("No fill").foregroundStyle(Theme.textDim)
                    }
                }
            }
        } else {
            DialogFrame(title: "Fill Layer", onOK: {}) { Text("The fill layer is no longer there.").foregroundStyle(Theme.textDim) }
        }
    }

    /// Layer ▸ Change Layer Content within the dialog.
    static func change(to k: FillKind) {
        guard let f = current?.fill, FillKind(f.paint) != k else { return }
        let app = AppModel.shared
        edit { f in
            switch k {
            case .solid:
                if case .gradient(let g) = f.paint, let c = g.gradient.sortedStops.first?.color { f.paint = .color(c) } else { f.paint = .color(app.foreground) }
            case .gradient:
                var g = GradientFill(gradient: .twoColor(f.paint.solidColor ?? app.foreground, app.background))
                g.alignWithLayer = true
                f.paint = .gradient(g)
            case .pattern:
                f.paint = .pattern(id: app.customPatterns.last?.id ?? "checker", scale: 1)
                if f.patternPlacement == nil { f.patternPlacement = PatternPlacement() }
            }
        }
        AppModel.shared.setStatus(statusHint(k))
    }

    static func statusHint(_ k: FillKind) -> String {
        switch k {
        case .solid: return "Click in the image to pick a colour"
        case .gradient: return "Drag in the image to move the gradient"
        case .pattern: return "Drag in the image to move the pattern"
        }
    }
}

// MARK: - Gradient Fill

struct GradientFillControls: View {
    let g: GradientFill
    let layer: Layer

    func set(_ body: @escaping (inout GradientFill) -> Void) {
        FillLayerDialog.edit { f in
            guard case .gradient(var gf) = f.paint else { return }
            body(&gf)
            f.paint = .gradient(gf)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Gradient")
            HStack {
                GradientPresetGrid(selected: Binding(get: { g.gradient }, set: { v in set { $0.gradient = v } })).fixedSize()
                Spacer(minLength: 0)
            }
            GradientStopsEditor(gradient: Binding(get: { g.gradient }, set: { v in set { $0.gradient = v } }))
            Divider()
            HStack(spacing: 8) {
                Text("Style").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { g.type }, set: { v in set { $0.type = v } })) {
                    ForEach(GradientType.allCases) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 120)
                Spacer()
                Text("Angle").foregroundStyle(Theme.textDim)
                AngleDial(angle: Binding(get: { g.angle }, set: { v in set { $0.angle = v } }))
                NumberField(label: "", value: Binding(get: { g.angle }, set: { v in set { $0.angle = max(-360, min(360, v)) } }), width: 40, format: "%.0f")
                Text("°").foregroundStyle(Theme.textFaint)
            }
            ValueSlider(label: "Scale", value: Binding(get: { g.scale * 100 }, set: { v in set { $0.scale = max(0.1, v / 100) } }), range: 10...1000, unit: "%", labelWidth: 52)
            HStack(spacing: 8) {
                Text("Method").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { g.method ?? .classic }, set: { v in set { $0.method = v == .classic ? nil : v } })) {
                    ForEach(GradientMethod.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .help("Perceptual: even-looking steps · Linear: light-accurate blending · Classic: sRGB blending (Photoshop before 2023)")
            }
            HStack(spacing: 14) {
                Toggle("Reverse", isOn: Binding(get: { g.reverse }, set: { v in set { $0.reverse = v } })).toggleStyle(.checkbox)
                Toggle("Dither", isOn: Binding(get: { g.dither }, set: { v in set { $0.dither = v } })).toggleStyle(.checkbox)
                    .help("Adds a trace of noise so smooth gradients don't band")
                Toggle("Align with layer", isOn: Binding(get: { g.alignWithLayer == true }, set: { v in set { $0.alignWithLayer = v } })).toggleStyle(.checkbox)
                    .help("Spans the gradient over the layer's mask instead of the whole canvas")
            }
            HStack(spacing: 6) {
                Text("Offset").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                NumberField(label: "X", value: Binding(get: { Double(g.offset?.x ?? 0) }, set: { v in set { $0.offset = CGPoint(x: v, y: $0.offset?.y ?? 0) } }), width: 44, format: "%.1f")
                NumberField(label: "Y", value: Binding(get: { Double(g.offset?.y ?? 0) }, set: { v in set { $0.offset = CGPoint(x: $0.offset?.x ?? 0, y: v) } }), width: 44, format: "%.1f")
                Text("%").foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Reset Alignment") { set { $0.offset = nil } }.buttonStyle(PanelButtonStyle())
                    .help("Centres the gradient again after dragging it")
            }
            Text("Drag in the image to move the gradient.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

// MARK: - Pattern Fill

struct PatternFillControls: View {
    let id: String
    let scale: Double
    let placement: PatternPlacement
    @Bindable private var app = AppModel.shared

    func setPlacement(_ body: @escaping (inout PatternPlacement) -> Void) {
        FillLayerDialog.edit { f in
            var p = f.patternPlacement ?? PatternPlacement()
            body(&p)
            f.patternPlacement = p
        }
    }

    func setPattern(_ nid: String, _ ns: Double) {
        FillLayerDialog.edit { f in f.paint = .pattern(id: nid, scale: ns) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                PatternThumb(pattern: PatternLibrary.pattern(id: id, custom: app.customPatterns)).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(PatternLibrary.pattern(id: id, custom: app.customPatterns)?.name ?? "Missing pattern").font(Theme.fontBold)
                    if let p = PatternLibrary.pattern(id: id, custom: app.customPatterns) {
                        Text("\(p.image.width) × \(p.image.height) px tile").foregroundStyle(Theme.textDim)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !app.customPatterns.isEmpty {
                        Caption("Document & Custom")
                        grid(app.customPatterns)
                    }
                    Caption("Library")
                    grid(PatternDef.builtIn)
                }
            }
            .frame(height: 130)
            Divider()
            HStack(spacing: 8) {
                Text("Angle").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                AngleDial(angle: Binding(get: { placement.angle }, set: { v in setPlacement { $0.angle = v } }))
                NumberField(label: "", value: Binding(get: { placement.angle }, set: { v in setPlacement { $0.angle = max(-360, min(360, v)) } }), width: 40, format: "%.0f")
                Text("°").foregroundStyle(Theme.textFaint)
            }
            ValueSlider(label: "Scale", value: Binding(get: { scale * 100 }, set: { v in setPattern(id, max(0.01, v / 100)) }), range: 1...1000, unit: "%", labelWidth: 52)
            HStack(spacing: 6) {
                Text("Offset").foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                NumberField(label: "X", value: Binding(get: { Double(placement.offset.x) }, set: { v in setPlacement { $0.offset.x = CGFloat(v) } }), width: 44, format: "%.0f")
                NumberField(label: "Y", value: Binding(get: { Double(placement.offset.y) }, set: { v in setPlacement { $0.offset.y = CGFloat(v) } }), width: 44, format: "%.0f")
                Text("px").foregroundStyle(Theme.textFaint)
            }
            HStack(spacing: 10) {
                Toggle("Link with Layer", isOn: Binding(get: { placement.linked }, set: { v in setPlacement { $0.linked = v } })).toggleStyle(.checkbox)
                    .help("Moves the pattern with the layer when the layer is moved")
                Spacer()
                Button("Snap to Origin") { setPlacement { $0.offset = .zero } }.buttonStyle(PanelButtonStyle())
                    .help("Puts the pattern's corner back on the document's top-left corner")
            }
            Text("Drag in the image to move the pattern.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }

    func grid(_ list: [PatternDef]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
            ForEach(list) { p in
                PatternThumb(pattern: p).frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(p.id == id ? Theme.accent : .clear, lineWidth: 2))
                    .onTapGesture { setPattern(p.id, scale) }
                    .help(p.name)
            }
        }
    }
}

// MARK: - Shape + vector mask

enum ShapeMaskOps {
    /// Makes the shape the part of itself its vector mask shows (Photoshop: paste the mask path into the shape with
    /// Intersect Shape Areas): the shape's own stroke then runs along the cut edge as well. A one-piece mask stays a live
    /// component (Path Selection can still move it); a mask of several pieces is merged into the outline.
    static func intersectWithVectorMask(_ d: Document, _ id: UUID) {
        guard let l = d.state.layer(id), let s = l.shape, let vm = l.vectorMask, !vm.isEmpty else { Beep.play(); return }
        var p = s.path
        if vm.subpaths.count == 1, vm.subpaths[0].closed {
            p.subpaths += vm.withOperation(.intersect).subpaths
        } else {
            let a = PathBoolean.resolve(p).path, b = PathBoolean.resolve(vm).path
            p = VectorPath.from(cgPath: a.intersection(b, using: .winding))
        }
        d.updateLayer(id) { l in
            guard var sh = l.shape else { return }
            sh.geometry = .path(p)
            sh.transform = .identity
            sh.perspective = nil
            l.shape = sh
            l.vectorMask = nil
        }
        d.commit("Intersect Shape with Vector Mask")
    }
}
