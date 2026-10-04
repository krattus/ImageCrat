import AppKit
import SwiftUI
import ImageCratCore

/// Shared state between the Blur Gallery dialog and its on-canvas pins.
@Observable
final class BlurGalleryState {
    var inst: FilterInstance
    var selectedPin: UUID?
    let smartLayer: UUID?

    init(kind: FilterKind, smartLayer: UUID?) {
        var i = FilterInstance(kind: kind)
        switch kind {
        case .fieldBlur: i.points = [FilterPin(x: 0.5, y: 0.5, value: 15)]
        case .irisBlur: i.points = [FilterPin(x: 0.5, y: 0.5, value: 0)]
        case .pathBlur: i.points = [FilterPin(x: 0.3, y: 0.55, value: 0), FilterPin(x: 0.7, y: 0.45, value: 0)]
        default: break
        }
        inst = i
        selectedPin = i.points.first?.id
        self.smartLayer = smartLayer
    }
}

final class BlurGallerySession: InteractiveSession {
    let state: BlurGalleryState
    let doc: Document
    private var dragPin: UUID?
    var title: String { state.inst.kind.displayName }

    init(state: BlurGalleryState, doc: Document) {
        self.state = state
        self.doc = doc
    }

    private func norm(_ p: CGPoint) -> (Double, Double) { (Double(p.x) / Double(doc.state.width), Double(p.y) / Double(doc.state.height)) }
    private func docPoint(_ pin: FilterPin) -> CGPoint { CGPoint(x: pin.x * Double(doc.state.width), y: pin.y * Double(doc.state.height)) }

    func mouseDown(_ e: ToolEvent, canvas: CanvasView) {
        if let pin = state.inst.points.first(where: { canvas.docToView(docPoint($0)).distance(to: e.view) < 10 }) {
            if e.option && state.inst.kind == .fieldBlur && state.inst.points.count > 1 {
                state.inst.points.removeAll { $0.id == pin.id }
                state.selectedPin = state.inst.points.first?.id
                return
            }
            dragPin = pin.id
            state.selectedPin = pin.id
            return
        }
        if state.inst.kind == .fieldBlur {
            let (x, y) = norm(e.doc)
            let v = state.inst.points.first { $0.id == state.selectedPin }?.value ?? 15
            let p = FilterPin(x: x, y: y, value: v)
            state.inst.points.append(p)
            state.selectedPin = p.id
            dragPin = p.id
        } else if state.inst.kind == .irisBlur, !state.inst.points.isEmpty {
            dragPin = state.inst.points[0].id
            let (x, y) = norm(e.doc)
            state.inst.points[0].x = x; state.inst.points[0].y = y
        }
    }

    func mouseDragged(_ e: ToolEvent, canvas: CanvasView) {
        guard let id = dragPin, let i = state.inst.points.firstIndex(where: { $0.id == id }) else { return }
        let (x, y) = norm(e.doc)
        state.inst.points[i].x = clamp(x, 0, 1); state.inst.points[i].y = clamp(y, 0, 1)
    }

    func mouseUp(_ e: ToolEvent, canvas: CanvasView) { dragPin = nil }

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        let inst = state.inst
        if inst.kind == .irisBlur, let c = inst.points.first {
            let W = CGFloat(doc.state.width), H = CGFloat(doc.state.height)
            let rx = CGFloat(inst.value("rx")) * W / 2, ry = CGFloat(inst.value("ry")) * H / 2
            let rot = CGFloat(inst.value("rotation") * .pi / 180)
            let center = docPoint(c)
            for scale in [1.0, 1.0 - inst.value("feather")] {
                let p = CGMutablePath()
                for k in 0...64 {
                    let a = CGFloat(k) / 64 * 2 * .pi
                    let local = CGPoint(x: cos(a) * rx * CGFloat(scale), y: sin(a) * ry * CGFloat(scale))
                    let rp = CGPoint(x: local.x * cos(-rot) - local.y * sin(-rot), y: local.x * sin(-rot) + local.y * cos(-rot))
                    let v = canvas.docToView(center + rp)
                    if k == 0 { p.move(to: v) } else { p.addLine(to: v) }
                }
                OverlayStyle.contrastStroke(ctx, p, dashed: scale < 1)
            }
        }
        if inst.kind == .pathBlur, inst.points.count >= 2 {
            let p = CGMutablePath()
            p.move(to: canvas.docToView(docPoint(inst.points[0])))
            p.addLine(to: canvas.docToView(docPoint(inst.points[1])))
            OverlayStyle.contrastStroke(ctx, p, width: 2)
        }
        for pin in inst.points {
            let v = canvas.docToView(docPoint(pin))
            let sel = pin.id == state.selectedPin
            ctx.setFillColor(NSColor.white.withAlphaComponent(sel ? 1 : 0.7).cgColor)
            ctx.fillEllipse(in: CGRect(x: v.x - 7, y: v.y - 7, width: 14, height: 14))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: v.x - 7, y: v.y - 7, width: 14, height: 14))
            if inst.kind == .fieldBlur {
                OverlayStyle.label("\(Int(pin.value)) px", at: CGPoint(x: v.x - 10, y: v.y - 30))
            }
        }
    }

    func commit() {
        AppActions.finishBlurGallery(state, apply: true)
    }

    func cancel() {
        AppActions.finishBlurGallery(state, apply: false)
    }
}

extension AppActions {
    static var blurGallery: BlurGalleryState?

    static func startBlurGallery(_ kind: FilterKind) {
        guard let c = canvas, let d = doc, let l = d.activeLayer else { return }
        if !l.isRaster && !l.isSmartObject { offerRasterize(layer: l.id); return }
        c.commitCurrentTool()
        app.tool = .move
        let st = BlurGalleryState(kind: kind, smartLayer: l.isSmartObject ? l.id : nil)
        if st.smartLayer != nil { st.inst = withSelectionMask(st.inst, d) }   // the selection becomes the filter mask
        blurGallery = st
        (c.tool(for: .move) as? MoveTool)?.interactive = BlurGallerySession(state: st, doc: d)
        app.dialog = .blurGallery
        updateBlurGalleryPreview()
    }

    static func updateBlurGalleryPreview() {
        guard let st = blurGallery, let d = doc else { return }
        let f = st.inst
        if let sl = st.smartLayer {
            var filters = d.committedState.layer(sl)?.smart?.filters ?? []
            filters.append(f)
            d.updateLayer(sl) { $0.smart?.filters = filters }
        } else {
            let canvasRect = CanvasSpace(width: d.state.width, height: d.state.height).ciCanvas
            setPreview { f.apply($0, canvas: canvasRect) }
        }
        canvas?.overlay.needsDisplay = true
    }

    static func finishBlurGallery(_ st: BlurGalleryState, apply: Bool) {
        guard let d = doc, blurGallery === st else { return }
        blurGallery = nil
        if let mt = canvas?.tool(for: .move) as? MoveTool, mt.interactive is BlurGallerySession { mt.interactive = nil }
        if app.dialog == .blurGallery { app.dialog = nil }
        if let sl = st.smartLayer {
            if apply {
                var filters = d.committedState.layer(sl)?.smart?.filters ?? []
                filters.append(st.inst)
                d.updateLayer(sl) { $0.smart?.filters = filters }
                d.commit(st.inst.kind.displayName)
            } else {
                d.revertUncommitted()
            }
            return
        }
        setPreview(nil)
        if apply { applyFilter(st.inst) }
    }
}

struct BlurGalleryDialog: View {
    @Bindable var st: BlurGalleryState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(st.inst.kind.displayName + (st.smartLayer != nil ? " (Smart Filter)" : AppActions.filterTargetSuffix(AppActions.doc))).font(.system(size: 13, weight: .semibold))
            switch st.inst.kind {
            case .fieldBlur:
                if let i = st.inst.points.firstIndex(where: { $0.id == st.selectedPin }) {
                    ValueSlider(label: "Blur", value: $st.inst.points[i].value, range: 0...500, unit: "px", labelWidth: 50)
                }
                Text("Click the image to add pins · drag to move · ⌥-click a pin to delete.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            case .irisBlur:
                ForEach(st.inst.kind.params) { p in slider(p) }
                Text("Drag the center pin to move the focus area.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            case .pathBlur:
                ForEach(st.inst.kind.params) { p in slider(p) }
                Text("Drag the two endpoints to set the motion path.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            default: EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel") { AppActions.finishBlurGallery(st, apply: false) }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { FieldEdits.commit(); AppActions.finishBlurGallery(st, apply: true) }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 320)
        .onChange(of: st.inst) { _, _ in AppActions.updateBlurGalleryPreview() }
    }

    @ViewBuilder func slider(_ p: FilterParam) -> some View {
        let b = Binding(get: { st.inst.values[p.key] ?? p.defaultValue }, set: { st.inst.values[p.key] = $0 })
        switch p.kind {
        case .slider(let r): ValueSlider(label: p.label, value: b, range: r, unit: p.unit, format: r.upperBound <= 2 ? "%.2f" : "%.0f", labelWidth: 70)
        case .angle: HStack { Text(p.label).foregroundStyle(Theme.textDim).frame(width: 70, alignment: .leading); AngleDial(angle: b); NumberField(label: "", value: b, width: 44) }
        default: EmptyView()
        }
    }
}
