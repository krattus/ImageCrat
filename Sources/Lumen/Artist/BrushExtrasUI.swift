import AppKit
import SwiftUI
import ImageCratCore

// Drawing Assist panel (guides, rulers, stabiliser, palette jitter, wrap, eyedropper ring), the options-bar assist
// menu and the Brush Test Pad.

// MARK: - Drawing Assist panel

struct DrawingAssistPanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var settings = ArtistSettings.shared
    @Bindable var groups = SwatchGroupStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let d = app.activeDocument { GuideControls(doc: d) } else {
                    Text("Open a document to set up drawing guides.").foregroundStyle(Theme.textFaint)
                }
                Divider()
                Caption("Stroke stabiliser")
                Picker("", selection: $settings.prefs.stabilizer) { ForEach(StabilizerMode.allCases) { Text(tr($0.title)).tag($0) } }
                    .labelsHidden().segmentedOrMenu()
                if settings.prefs.stabilizer == .rope {
                    ValueSlider(label: "Rope Length", value: $settings.prefs.ropeLength, range: 4...200, step: 1, unit: "px")
                    Text("The brush is pulled on a string: it only moves once the pen is a rope length away, and changes direction only when you pull the other way.")
                        .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
                } else if settings.prefs.stabilizer == .average {
                    ValueSlider(label: "Samples", value: Binding(get: { Double(settings.prefs.averageWindow) }, set: { settings.prefs.averageWindow = Int($0) }), range: 2...64, step: 1)
                }
                if settings.prefs.stabilizer != .off { Toggle2(label: "Catch up to the pen when the stroke ends", on: $settings.prefs.catchUp) }
                Divider()
                Caption("Colour jitter from palette")
                Picker("", selection: $settings.prefs.paletteJitter) { ForEach(PaletteJitterMode.allCases) { Text(tr($0.title)).tag($0) } }
                    .labelsHidden().segmentedOrMenu()
                if settings.prefs.paletteJitter != .off {
                    Picker("Palette", selection: $settings.prefs.paletteGroup) {
                        Text("Swatches panel").tag(UUID?.none)
                        ForEach(groups.groups) { g in Text(tr(g.name)).tag(UUID?.some(g.id)) }
                    }
                    WrappingHStack(spacing: 2, lineSpacing: 2) {
                        ForEach(Array(BrushAssist.palette.prefix(16).enumerated()), id: \.offset) { _, c in SwatchChip(color: c, size: 12) }
                    }
                }
                Divider()
                Caption("Seamless tiles")
                Toggle2(label: "Wrap painting around the canvas edges", on: $settings.prefs.wrapPainting)
                WrappingHStack {
                    Button("Pattern Preview") { if let d = app.activeDocument { PatternPreview.toggle(d) } }.buttonStyle(PanelButtonStyle())
                    Button("Make Seamless…") { DialogRegistry.show("artist.seamless") }.buttonStyle(PanelButtonStyle())
                }.disabled(app.activeDocument == nil)
                Divider()
                Caption("Eyedropper")
                Toggle2(label: "Show the average-colour ring", on: $settings.prefs.eyedropperRing)
                ValueSlider(label: "Average of", value: Binding(get: { Double(app.eyedropperSample) }, set: { app.eyedropperSample = max(1, Int($0) | 1) }), range: 1...101, step: 2, unit: "px")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font).foregroundStyle(Theme.text)
    }
}

struct GuideControls: View {
    @Bindable var doc: Document
    @Bindable var settings = ArtistSettings.shared

    private func live(_ body: (inout DrawingGuide) -> Void) {
        body(&doc.state.artist.guide)
        doc.setNeedsOverlay()
    }
    private func commit() { doc.commit("Edit Drawing Guide") }

    var body: some View {
        let g = doc.state.artist.guide
        Caption("Drawing guide")
        Picker("", selection: Binding(get: { g.kind }, set: { DrawingGuides.setKind($0) })) {
            ForEach(DrawingGuideKind.allCases) { Text(tr($0.title)).tag($0) }
        }.labelsHidden()
        Toggle2(label: "Assisted drawing (strokes snap to the guide and rulers)", on: $settings.prefs.assist)
        WrappingHStack(spacing: 12) {
            Toggle2(label: "Show", on: Binding(get: { g.visible }, set: { v in live { $0.visible = v }; commit() }))
            Toggle2(label: "Edit handles", on: Binding(get: { settings.editGuides }, set: { settings.editGuides = $0; doc.setNeedsOverlay() }))
            ColorWell(color: Binding(get: { g.color }, set: { c in live { $0.color = c } }), size: 14, onCommit: commit)
        }
        if g.kind != .none {
            switch g.kind {
            case .isometric:
                ValueSlider(label: "Angle", value: Binding(get: { g.isoAngle }, set: { v in live { $0.isoAngle = v } }), range: 5...60, unit: "°", onCommit: commit)
                ValueSlider(label: "Spacing", value: Binding(get: { g.spacing }, set: { v in live { $0.spacing = v } }), range: 8...400, unit: "px", onCommit: commit)
            case .grid:
                ValueSlider(label: "Angle", value: Binding(get: { g.gridAngle }, set: { v in live { $0.gridAngle = v } }), range: -90...90, unit: "°", onCommit: commit)
                ValueSlider(label: "Spacing", value: Binding(get: { g.spacing }, set: { v in live { $0.spacing = v } }), range: 4...400, unit: "px", onCommit: commit)
            case .radial:
                ValueSlider(label: "Spokes", value: Binding(get: { Double(g.spokes) }, set: { v in live { $0.spokes = Int(v) } }), range: 2...72, step: 1, onCommit: commit)
                ValueSlider(label: "Rings", value: Binding(get: { g.spacing }, set: { v in live { $0.spacing = v } }), range: 8...400, unit: "px", onCommit: commit)
            case .perspective1:
                ValueSlider(label: "Horizon", value: Binding(get: { g.horizonAngle }, set: { v in live { $0.horizonAngle = v } }), range: -90...90, unit: "°", onCommit: commit)
            default:
                Text("Drag the vanishing points on the canvas (they can sit outside it).").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            ValueSlider(label: "Opacity", value: Binding(get: { g.opacity * 100 }, set: { v in live { $0.opacity = v / 100 } }), range: 10...100, unit: "%", onCommit: commit)
        }
        Caption("Rulers")
        WrappingHStack(spacing: 4) {
            ForEach(AssistRulerKind.allCases) { k in
                Button(tr(k == .straight ? "+ Straight" : k == .ellipse ? "+ Ellipse" : "+ Curve")) { DrawingGuides.addRuler(k) }.buttonStyle(PanelButtonStyle()).help("Add a \(k.title.lowercased())")
            }
        }
        ForEach(doc.state.artist.rulers) { r in
            HStack {
                Image(systemName: r.kind == .straight ? "ruler" : r.kind == .ellipse ? "oval" : "scribble").foregroundStyle(Theme.textDim)
                Text(tr(r.kind.title))
                Spacer()
                IconButton(symbol: "trash", help: "Remove ruler", size: 18) { DrawingGuides.removeRuler(r.id) }
            }
        }
        if !doc.state.artist.rulers.isEmpty {
            Text("A stroke that starts near a ruler follows it (at the distance where it started). ⌥-click a ruler handle to delete it.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Options bar menu

/// Options-bar menu for brush-type tools: assisted drawing, stabiliser, wrap and the test pad popover.
struct AssistMenu: View {
    @Bindable var settings = ArtistSettings.shared
    @State private var showPad = false

    var body: some View {
        let p = settings.prefs
        let active = p.stabilizer != .off || (p.assist && hasGuide) || p.wrapPainting || p.paletteJitter != .off
        Menu {
            Toggle("Assisted Drawing", isOn: $settings.prefs.assist)
            Menu("Drawing Guide") {
                ForEach(DrawingGuideKind.allCases) { k in Button(tr(k.title)) { DrawingGuides.setKind(k) } }
            }
            Divider()
            Picker("Stabiliser", selection: $settings.prefs.stabilizer) { ForEach(StabilizerMode.allCases) { Text(tr($0.title)).tag($0) } }
            Toggle("Catch Up on Stroke End", isOn: $settings.prefs.catchUp)
            Divider()
            Picker("Colour Jitter from Palette", selection: $settings.prefs.paletteJitter) { ForEach(PaletteJitterMode.allCases) { Text(tr($0.title)).tag($0) } }
            Toggle("Wrap Painting (Seamless Tiles)", isOn: $settings.prefs.wrapPainting)
            Divider()
            Button("Drawing Assist Panel…") { WorkspaceManager.shared.reveal("drawingAssist") }
        } label: {
            Image(systemName: "pencil.and.ruler").foregroundStyle(active ? Theme.accent : Theme.text)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Drawing assists: guides, stabiliser, palette colour jitter, wrap painting")
        IconButton(symbol: "square.and.pencil", help: "Brush Test Pad: try the brush without touching the document", active: showPad) { showPad.toggle() }
            .popover(isPresented: $showPad, arrowEdge: .bottom) { BrushTestPadPanel().frame(width: 420, height: 300) }
    }

    private var hasGuide: Bool {
        guard let d = AppActions.doc else { return false }
        return d.state.artist.guide.kind != .none || !d.state.artist.rulers.isEmpty
    }
}

// MARK: - Brush Test Pad

/// A scratch document that is never added to the app: strokes go through the real brush engine (current tool settings,
/// dynamics, stabiliser and palette jitter) but guides, symmetry and wrap-around are ignored.
final class BrushTestPad {
    static let shared = BrushTestPad()
    private(set) var doc: Document
    private(set) var layerID: UUID
    private var stroke: PaintStroke?
    private var engine: BrushDynamicsEngine?
    var onChange: (() -> Void)?

    init(width: Int = 640, height: Int = 400) {
        let made = BrushTestPad.makeDoc(width, height)
        doc = made.0
        layerID = made.1
    }

    private static func makeDoc(_ w: Int, _ h: Int) -> (Document, UUID) {
        var st = DocumentState(width: w, height: h)
        let bg = PixelBuffer(width: w, height: h)
        bg.context.setFillColor(RGBA.white.cgColor)
        bg.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bg.markDirty()
        let l = Layer.raster(name: "Pad", width: w, height: h)
        st.layers = [Layer.raster(name: "Background", buffer: bg), l]
        return (Document(state: st, name: "Test Pad"), l.id)
    }

    var size: CGSize { CGSize(width: doc.state.width, height: doc.state.height) }

    func clear() {
        cancel()
        (doc, layerID) = BrushTestPad.makeDoc(doc.state.width, doc.state.height)
        onChange?()
    }

    private func cancel() {
        if stroke != nil { doc.contentOverrides.removeAll(); doc.revertUncommitted() }
        stroke = nil; engine = nil
        ArtistContext.padActive = false
    }

    func begin(_ s: PenSample) {
        cancel()
        let app = AppModel.shared
        let bs = app.activeBrushSettings
        let erasing = app.tool == .eraser || app.tool == .backgroundEraser
        guard let st = PaintStroke(doc: doc, layerID: layerID, target: .content, opacity: bs.opacity, blend: erasing ? .destinationOut : bs.blendMode.cgBlendMode) else { return }
        st.setPreviewBlend(erasing ? .normal : bs.blendMode)
        let eng = BrushDynamicsEngine(settings: bs, target: st.strokeBuf, origin: st.origin,
                                      paint: erasing ? .fixed(.black) : .dynamic(fg: app.foreground, bg: app.background), aliased: app.tool == .pencil)
        st.dynamics = eng
        stroke = st; engine = eng
        ArtistContext.padActive = true
        eng.begin(s)
        st.flush()
        onChange?()
    }

    func move(_ s: PenSample) {
        guard let st = stroke, let eng = engine else { return }
        ArtistContext.padActive = true
        eng.move(s)
        st.flush()
        onChange?()
    }

    func end(_ s: PenSample) {
        guard let st = stroke, let eng = engine else { return }
        ArtistContext.padActive = true
        eng.move(s, final: true)
        st.finish(name: "Test Stroke")
        stroke = nil; engine = nil
        doc = Document(state: doc.state, name: "Test Pad")     // the pad keeps no undo history
        ArtistContext.padActive = false
        BrushAssist.leash = nil
        onChange?()
    }

    func image() -> CGImage? {
        RenderEngine.cgImage(Compositor.shared.composite(doc), rect: CanvasSpace(width: doc.state.width, height: doc.state.height).ciCanvas)
    }
}

final class BrushTestPadView: NSView {
    let pad = BrushTestPad.shared
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pad.onChange = { [weak self] in self?.needsDisplay = true }
    }

    /// Pad pixels per view point (the pad is shown fitted into the view).
    private var scale: CGFloat { max(pad.size.width / max(1, bounds.width), pad.size.height / max(1, bounds.height)) }
    private var shown: CGRect {
        let s = scale
        let w = pad.size.width / s, h = pad.size.height / s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fill(bounds)
        guard let img = pad.image() else { return }
        let r = shown
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
        if let l = BrushAssist.leash, ArtistContext.padActive {
            func v(_ p: CGPoint) -> CGPoint { CGPoint(x: r.minX + p.x / scale, y: r.minY + p.y / scale) }
            ArtistOverlays.drawLeash(ctx, tip: v(l.tip), pen: v(l.pen), length: l.length / scale)
        }
    }

    /// The pen sample of an event, through the Preferences ▸ Tablet curve like the canvas.
    private func sample(_ e: NSEvent, _ phase: TabletInput.Phase) -> PenSample {
        let v = convert(e.locationInWindow, from: nil)
        let r = shown
        let t = TabletInput.shared.reading(e, phase: phase)
        var s = PenSample(p: CGPoint(x: (v.x - r.minX) * scale, y: (v.y - r.minY) * scale), pressure: t.pressure)
        s.tilt = t.tilt; s.rotation = t.rotation
        s.wheel = t.isTablet ? min(1, abs(t.tangential)) : 1
        s.mouse = !t.isTablet
        return s
    }

    override func mouseDown(with e: NSEvent) { TabletInput.shared.beginStroke(painting: true); pad.begin(sample(e, .down)) }
    override func mouseDragged(with e: NSEvent) { pad.move(sample(e, .drag)) }
    override func mouseUp(with e: NSEvent) { pad.end(sample(e, .up)); TabletInput.shared.endStroke() }
}

struct BrushTestPadRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> BrushTestPadView { BrushTestPadView() }
    func updateNSView(_ v: BrushTestPadView, context: Context) { v.needsDisplay = true }
}

struct BrushTestPadPanel: View {
    @Bindable var app = AppModel.shared

    var body: some View {
        let s = app.activeBrushSettings
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BrushTipPreview(settings: s).frame(width: 18, height: 18)
                Text("\(Int(s.size)) px · \(Int(s.opacity * 100))% · \(PieRenderer.shortName(app.tool))").font(Theme.fontSmall).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer()
                Button("Clear") { BrushTestPad.shared.clear() }.buttonStyle(PanelButtonStyle())
            }
            .padding(.horizontal, 8).frame(height: 30)
            BrushTestPadRepresentable()
        }
        .font(Theme.font).foregroundStyle(Theme.text)
    }
}
