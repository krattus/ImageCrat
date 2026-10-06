import AppKit
import SwiftUI
import ImageCratCore

// MARK: - The shape tools' options bar, per mode (Photoshop)
//
//  Shape:  Fill · Stroke · width · stroke type · W / H · path operations · path alignment · gear
//          (with a shape layer selected the bar shows that layer's Fill and Stroke and edits it, one undo step per change;
//          a new shape gets exactly what the bar shows)
//  Path:   Make: Selection… / Mask / Shape · path operations · path alignment · gear (no Fill / Stroke: nothing is painted)
//  Pixels: Mode · Opacity · Anti-alias (paints the foreground colour onto the selected pixel layer; no Fill / Stroke)

enum ShapeBar {
    static var app: AppModel { AppModel.shared }

    /// The shape layer the bar shows and edits: the selected layer when it is a shape layer.
    static func target(_ d: Document?) -> (Document, UUID, ShapeContent)? {
        guard let d, let l = d.activeLayer, let s = l.shape else { return nil }
        return (d, l.id, s)
    }

    /// The options bar's stroke settings as one style.
    static func toolStroke() -> StrokeStyle { ShapeStrokeOptionsButton.toolStroke(app.shapeTool) }

    /// What the bar shows, so what a new shape gets: the selected shape layer's Fill and Stroke, else the tool's.
    static func style(_ d: Document?) -> (fill: PaintStyle, stroke: StrokeStyle) {
        if let (_, _, s) = target(d) { return (s.fill, s.stroke) }
        var st = toolStroke()
        if app.shapeTool.stroke.isNone { st.paint = .none }
        return (app.shapeTool.fill, st)
    }

    /// The tool keeps the style last used (shown again when no shape layer is selected).
    static func remember(fill: PaintStyle, stroke: StrokeStyle) {
        var t = app.shapeTool
        t.fill = fill
        t.stroke = stroke.paint
        t.strokeWidth = stroke.width
        t.strokeAlignment = stroke.alignment
        var o = stroke; o.paint = .none
        t.strokeOptions = o
        if t != app.shapeTool { app.shapeTool = t }
    }

    // MARK: Editing from the bar

    /// Document whose selected shape was changed live and still needs its history step.
    nonisolated(unsafe) private static var pendingDocID: UUID?

    private static func editTarget(_ body: (inout ShapeContent) -> Void) {
        guard let (d, id, _) = target(app.activeDocument), d.state.layer(id)?.locks.all != true else { return }
        d.updateLayer(id) { l in
            guard var s = l.shape else { return }
            body(&s)
            l.shape = s
        }
        pendingDocID = d.id
    }

    static func setFill(_ v: PaintStyle) {
        app.shapeTool.fill = v
        editTarget { $0.fill = v }
    }

    static func setStrokePaint(_ v: PaintStyle) {
        app.shapeTool.stroke = v
        editTarget { $0.stroke.paint = v }
    }

    static func setStrokeWidth(_ v: Double) {
        // dashes typed in px keep their length when the width changes
        var s = toolStroke(); s.setWidth(v)
        app.shapeTool.strokeWidth = s.width
        if app.shapeTool.strokeOptions != nil { s.paint = .none; app.shapeTool.strokeOptions = s }
        editTarget { $0.stroke.setWidth(v) }
    }

    /// W / H: the selected shape scaled from its top-left corner.
    static func setSize(width: Double? = nil, height: Double? = nil) {
        editTarget { s in
            guard s.perspective == nil else { return }
            let b = s.path.bounds
            let sx = width.map { max(1, $0) / max(1, Double(b.width)) } ?? 1
            let sy = height.map { max(1, $0) / max(1, Double(b.height)) } ?? 1
            let t = CGAffineTransform(translationX: b.minX, y: b.minY).scaledBy(x: CGFloat(sx), y: CGFloat(sy)).translatedBy(x: -b.minX, y: -b.minY)
            s.transform = s.transform.concatenating(t)
        }
    }

    /// One history step for the live edits made since the last one (popover closed, field committed).
    static func commit(_ name: String) {
        guard let id = pendingDocID else { return }
        pendingDocID = nil
        app.documents.first { $0.id == id }?.commit(name)
    }

    static var fillBinding: Binding<PaintStyle> {
        Binding(get: { style(app.activeDocument).fill }, set: { setFill($0) })
    }
    static var strokeBinding: Binding<PaintStyle> {
        Binding(get: { style(app.activeDocument).stroke.paint }, set: { setStrokePaint($0) })
    }
    static var strokeWidthBinding: Binding<Double> {
        Binding(get: { style(app.activeDocument).stroke.width }, set: { setStrokeWidth($0) })
    }
}

// MARK: - Pixels mode

enum ShapePixels {
    /// Pixels mode: `path` painted with the foreground colour onto the selected pixel layer (or its mask / Quick Mask)
    /// with the options bar's Mode, Opacity and Anti-alias. A shape, type, fill or smart object layer is not painted:
    /// the app asks to rasterize it first, as every pixel tool does (Cancel leaves it untouched).
    static func paint(_ tool: Tool, _ path: VectorPath, name: String) {
        guard let (d, id, tgt) = tool.requirePixelTarget(), let (w, o) = d.beginPixelEdit(layerID: id, target: tgt) else { return }
        let app = AppModel.shared, st = app.shapeTool
        let ctx = w.context
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(-o.x), y: CGFloat(-o.y))
        if let sel = d.editSelection { w.clip(toMask: sel.makeCGImage(), in: d.state.canvasCGRect) }
        ctx.setAlpha(CGFloat(clamp(st.pixelOpacity, 0, 1)))
        var mode = st.pixelBlendMode.cgBlendMode
        if tgt == .content, d.state.layer(id)?.locks.transparency == true { mode = .sourceAtop }
        ctx.setBlendMode(mode)
        ctx.setShouldAntialias(st.pixelAntiAlias)
        let rp = path.resolved
        ctx.addPath(rp.path)
        ctx.setFillColor((tgt.isMask ? RGBA(gray: app.foreground.luminance) : app.foreground).cgColor)
        if rp.evenOdd { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
        ctx.restoreGState()
        w.markDirty()
        d.commit(name)
    }
}

// MARK: - ⌥⌫ on shape layers

extension AppActions {
    /// ⌥⌫ Fill with the foreground colour. Like Photoshop, selected shape layers (and solid colour fill layers) take the
    /// foreground colour as their fill instead of being rasterized; pixel layers are filled as before.
    static func fillForegroundShortcut() {
        guard let d = doc else { return }
        func recolorable(_ l: Layer) -> Bool {
            l.isShape || (l.fill.map { $0.recipe == nil && $0.paint.solidColor != nil } ?? false)
        }
        if !d.quickMask, let id = d.activeLayerID, let l = d.state.layer(id), !(d.editTarget == .mask && l.mask != nil), recolorable(l) {
            let fg = AppModel.shared.foreground
            var ids = d.withoutDescendants(d.orderedSelection).filter { d.state.layer($0).map(recolorable) ?? false }
            if !ids.contains(id) { ids.append(id) }
            var changed = false
            for lid in ids {
                guard let layer = d.state.layer(lid), !layer.locks.all else { continue }
                d.updateLayer(lid) { x in
                    if x.shape != nil { x.shape?.fill = .color(fg) } else { x.fill?.paint = .color(fg) }
                }
                changed = true
            }
            if changed { d.commit("Fill") } else { AppModel.shared.setStatus("The layer is locked."); Beep.play() }
            return
        }
        fill(.foreground, opacity: 1, mode: .normal, preserveTransparency: false)
    }
}

// MARK: - Bar views

/// Fill and Stroke swatches, stroke width and stroke type (Shape mode of the shape tools and the pens).
struct ShapeFillStrokeControls: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let _ = app.activeDocument?.activeLayer?.shape   // follows the selected shape layer
        Text("Fill").foregroundStyle(Theme.textDim)
        PaintStylePicker(paint: ShapeBar.fillBinding, onCommit: { ShapeBar.commit("Shape Fill") })
            .help("Fill of new shapes and of the selected shape layer")
        Text("Stroke").foregroundStyle(Theme.textDim)
        PaintStylePicker(paint: ShapeBar.strokeBinding, onCommit: { ShapeBar.commit("Shape Stroke") })
            .help("Stroke of new shapes and of the selected shape layer")
        NumberField(label: "", value: ShapeBar.strokeWidthBinding, width: 34, onCommit: { ShapeBar.commit("Stroke Width") })
            .help("Stroke width")
        Text("px").foregroundStyle(Theme.textFaint)
        ShapeStrokeOptionsButton()
    }
}

/// W / H of the selected shape layer (Photoshop's options bar fields); greyed out with no shape layer selected.
struct ShapeSizeFields: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let t = ShapeBar.target(app.activeDocument)
        let b = t?.2.path.bounds ?? .zero
        let editable = t != nil && t?.2.perspective == nil
        HStack(spacing: 4) {
            NumberField(label: "W", value: Binding(get: { Double(b.width) }, set: { ShapeBar.setSize(width: $0) }), width: 44,
                        onCommit: { ShapeBar.commit("Resize Shape") })
            NumberField(label: "H", value: Binding(get: { Double(b.height) }, set: { ShapeBar.setSize(height: $0) }), width: 44,
                        onCommit: { ShapeBar.commit("Resize Shape") })
        }
        .disabled(!editable)
        .opacity(editable ? 1 : 0.5)
        .help(tr(editable ? "Width and height of the selected shape" : "Select a shape layer to set its width and height"))
    }
}

/// Path alignment: aligns / distributes the selected layers (one layer: to the selection, or to the canvas).
struct PathAlignmentMenu: View {
    var body: some View {
        Menu {
            Button("Align Left Edges") { AppActions.align(.left) }
            Button("Align Horizontal Centers") { AppActions.align(.hCenter) }
            Button("Align Right Edges") { AppActions.align(.right) }
            Divider()
            Button("Align Top Edges") { AppActions.align(.top) }
            Button("Align Vertical Centers") { AppActions.align(.vCenter) }
            Button("Align Bottom Edges") { AppActions.align(.bottom) }
            Divider()
            Button("Distribute Horizontally") { AppActions.distribute(horizontal: true) }
            Button("Distribute Vertically") { AppActions.distribute(horizontal: false) }
        } label: {
            Image(systemName: "align.horizontal.left")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(AppModel.shared.activeDocument == nil)
        .help("Path alignment: align or distribute the selected shapes (one shape aligns to the selection or the canvas)")
    }
}

/// The gear: geometry options for new shapes.
struct ShapePathOptionsButton: View {
    @Bindable var app = AppModel.shared
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "gearshape") }
            .buttonStyle(.plain)
            .help("Path options: draw from the centre, keep the proportions")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Path Options").font(Theme.fontBold)
                    Toggle2(label: "From Center (or hold ⌥)", on: $app.shapeTool.fromCenter)
                    if app.tool != .line {
                        Toggle2(label: "Constrain Proportions (or hold ⇧)", on: $app.shapeTool.constrainProportions)
                    }
                }
                .colorPopoverContent()
            }
    }
}

/// Pixels mode: Mode, Opacity, Anti-alias (no Fill / Stroke: the foreground colour is painted).
struct ShapePixelsOptions: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        Text("Mode:").foregroundStyle(Theme.textDim)
        BlendModePicker(mode: $app.shapeTool.pixelBlendMode, width: 100)
        CompactSlider(label: "Opacity", value: $app.shapeTool.pixelOpacity, range: 0...1, unit: "%", scale: 100)
        Toggle2(label: "Anti-alias", on: $app.shapeTool.pixelAntiAlias)
        Text("Paints the foreground colour").foregroundStyle(Theme.textFaint)
    }
}

// MARK: - Colour / fill popovers

extension View {
    /// Content of a colour, fill or option popover: laid out at its natural (fitting) size, which the popover takes as
    /// its content size, so nothing is cut off on any side; on the opaque panel background (not the see-through glass).
    /// The panel-width environment is reset so a popover opened from a narrow panel uses the popover layout.
    func colorPopoverContent(padding: CGFloat = 12) -> some View {
        self.environment(\.panelWidth, .infinity)
            .padding(padding)
            .fixedSize()
            .background(Theme.panelBG)
            .environment(\.colorScheme, Theme.colorScheme)
    }
}
