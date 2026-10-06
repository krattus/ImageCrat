import AppKit
import CoreImage
import SwiftUI
import ImageCratCore

// MARK: - Centre of centre-based filters: what Object / Selection mean in a document
//
// The model (modes, stored keys, resolution) is in ImageCratCore (Model/Filters/FilterCenter.swift). This file says
// what the "object" and the "selection" are for the filter about to run, re-resolves filters that follow their content
// (Repeat Filter, actions, smart filters after the layer moved), remembers the last mode per filter and draws the
// Center controls of the filter dialog.

enum FilterCenterResolver {
    /// Context for a filter on the active target of `d`: the content it processes and the active selection.
    static func context(_ d: Document) -> FilterCenterContext {
        FilterCenterContext(canvasWidth: Double(d.state.width), canvasHeight: Double(d.state.height),
                            object: objectBounds(d), selection: d.state.selectionBounds?.cgRect)
    }

    /// Document bounds of what a filter on the active target processes: the alpha bounds of a pixel layer's pixels
    /// (of the layer mask while that is the edit target, of the selection in Quick Mask mode), a smart object's
    /// rendered content bounds, any other layer's content bounds. Nil when there is nothing.
    static func objectBounds(_ d: Document) -> CGRect? {
        if d.quickMask { return d.state.selectionBounds?.cgRect }
        guard let l = d.activeLayer else { return nil }
        if case .smartObject(let so) = l.content { return smartObjectBounds(so) }
        if AppActions.pixelTarget(d, l) == .mask, let m = l.mask {
            return m.buffer.opaqueBounds().map { $0.offsetBy(dx: m.origin.x, dy: m.origin.y).cgRect }
        }
        return Compositor.shared.contentBounds(l, state: d.state)
    }

    /// A smart object's rendered content bounds in document pixels: the bounds of its contents' pixels (or layers)
    /// mapped onto its quad, or onto its mesh warp.
    static func smartObjectBounds(_ so: SmartObjectContent) -> CGRect {
        if let w = so.warp, w.to.isValid, w.from.isValid { return w.mappedBounds(of: so.quad) }
        let src: CGRect, content: CGRect?
        switch so.source {
        case .image(let b):
            src = CGRect(x: 0, y: 0, width: b.width, height: b.height)
            content = b.opaqueBounds()?.cgRect
        case .document(let st):
            src = st.canvasCGRect
            var u: CGRect? = nil
            for l in st.layers where l.isVisible && !l.isAdjustment {
                if let b = Compositor.shared.contentBounds(l, state: st) { u = u.map { $0.union(b) } ?? b }
            }
            content = u?.intersection(src)
        }
        guard let c = content, !c.isNull, c.width > 0, c.height > 0, src.width > 0, src.height > 0,
              let h = Homography(from: Quad(rect: src), to: so.quad) else { return so.quad.bounds }
        let r = h.mapRect(c).bounds
        return [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) ? r : so.quad.bounds
    }

    /// `f` with its centre re-resolved for the document it runs on now, when its mode follows the content
    /// (Object, Selection). Filters without a centre option (or made before it) are returned unchanged.
    static func resolved(_ f: FilterInstance, _ d: Document?) -> FilterInstance {
        guard f.kind.usesCenter, f.centerMode != nil, let d else { return f }
        return f.reresolvedCenter(context(d))
    }

    /// Document bounds (y down) of the pixels of `img` (CI space of a `canvas`-size document) with any alpha, measured
    /// on at most 512 px on the long side; nil when it is empty. Recipe filter nodes centre on their input with it.
    static func alphaBounds(_ img: CIImage, canvas: CGRect) -> CGRect? {
        guard canvas.width >= 1, canvas.height >= 1, !canvas.isInfinite else { return nil }
        let s = min(1, 512 / max(canvas.width, canvas.height))
        let sp = CanvasSpace(width: max(1, Int((canvas.width * s).rounded(.up))), height: max(1, Int((canvas.height * s).rounded(.up))))
        let t = CGAffineTransform(translationX: -canvas.minX, y: -canvas.maxY).concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(sp.height)))
        let buf = RenderEngine.renderBuffer(img.transformed(by: t), docRect: IRect(x: 0, y: 0, width: sp.width, height: sp.height), space: sp)
        guard let b = buf.opaqueBounds() else { return nil }
        return CGRect(x: CGFloat(b.x) / s, y: CGFloat(b.y) / s, width: CGFloat(b.width) / s, height: CGFloat(b.height) / s)
            .intersection(CGRect(origin: .zero, size: canvas.size))
    }

    /// The smart filters of `so` as they render now: those in Object mode centred on the object where it is.
    static func smartContext(_ so: SmartObjectContent, space: CanvasSpace) -> FilterCenterContext {
        FilterCenterContext(canvasWidth: Double(space.width), canvasHeight: Double(space.height), object: smartObjectBounds(so))
    }
}

// MARK: - Last mode, remembered per filter

/// The Center mode (and a custom point) last used with each filter, remembered between launches. Automated runs
/// (self tests, fuzzing, scripts) neither read nor write the user's preferences.
enum FilterCenterMemory {
    static let key = "Lumen.Filters.CenterModes"
    static var automated: Bool { GenAIKeyOverrides.realKeysBlocked }
    /// kind raw value → [mode, custom x, custom y] (x / y normalized to the canvas).
    nonisolated(unsafe) static var memory: [String: [Double]] = automated ? [:] : (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:])

    static func mode(for k: FilterKind) -> FilterCenterMode {
        memory[k.rawValue]?.first.flatMap { $0.isFinite ? FilterCenterMode(rawValue: Int($0)) : nil } ?? k.defaultCenterMode
    }

    static func customPoint(for k: FilterKind) -> (x: Double, y: Double)? {
        guard let v = memory[k.rawValue], v.count >= 3, v[1].isFinite, v[2].isFinite else { return nil }
        return (v[1], v[2])
    }

    static func save(_ f: FilterInstance) {
        guard f.kind.usesCenter, let m = f.centerMode else { return }
        let c = f.centerPoint
        memory[f.kind.rawValue] = [Double(m.rawValue), c.x, c.y]
        if !automated { UserDefaults.standard.set(memory, forKey: key) }
    }

    /// A new filter dialog's starting point: the remembered mode (Selection while a selection is active and the
    /// remembered mode is Object, as Photoshop does; Object when Selection was remembered and there is none), resolved.
    static func start(_ inst: inout FilterInstance, _ ctx: FilterCenterContext) {
        guard inst.kind.usesCenter else { return }
        var m = mode(for: inst.kind)
        if m == .object && ctx.selection != nil { m = .selection }
        if m == .selection && ctx.selection == nil { m = .object }
        if m == .custom, let p = customPoint(for: inst.kind) {
            inst.values[FilterCenterKey.x] = p.x; inst.values[FilterCenterKey.y] = p.y
        }
        inst.resolveCenter(ctx, mode: m)
    }
}

// MARK: - Dialog controls

/// Center controls of a filter dialog: the mode, a thumbnail of the document with a draggable crosshair at the centre
/// (and the box / radius the effect is sized from), X / Y in document pixels and a "click on the canvas" picker.
struct FilterCenterSection: View {
    @Binding var f: FilterInstance
    let ctx: FilterCenterContext
    let thumbnail: CGImage?
    static let samplerToken = "filter.center"
    static let thumbBox = CGSize(width: 328, height: 150)

    var body: some View {
        let w = ctx.canvasWidth, h = ctx.canvasHeight
        let mode = f.centerMode ?? .canvas
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(tr(f.kind == .spotlight ? "Target" : "Center")).foregroundStyle(Theme.textDim).frame(width: 52, alignment: .leading)
                Picker("", selection: Binding(get: { mode }, set: { m in setMode(m) })) {
                    ForEach(FilterCenterMode.allCases) { m in Text(tr(m.title)).tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("Object: the middle of the layer's content · Selection: the middle of the selection · Canvas: the middle of the document · Custom: a point you pick")
            }
            thumb
            HStack(spacing: 8) {
                let c = f.centerPixel(canvasWidth: w, canvasHeight: h)
                NumberField(label: "X", value: Binding(get: { c.x }, set: { f.setCustomCenter(x: $0, y: c.y, canvasWidth: w, canvasHeight: h) }), width: 52)
                NumberField(label: "Y", value: Binding(get: { c.y }, set: { f.setCustomCenter(x: c.x, y: $0, canvasWidth: w, canvasHeight: h) }), width: 52)
                Text("px").foregroundStyle(Theme.textFaint)
                Spacer()
                let armed = CanvasSampler.shared.token == Self.samplerToken
                IconButton(symbol: "scope", help: "Click in the image to place the centre", active: armed) {
                    let binding = $f
                    CanvasSampler.shared.toggle(Self.samplerToken) { p, _ in
                        // click places the centre; dragging on (until the mouse goes up) moves it
                        func place(_ q: CGPoint) { binding.wrappedValue.setCustomCenter(x: Double(q.x), y: Double(q.y), canvasWidth: w, canvasHeight: h) }
                        place(p)
                        Self.endCanvasDrag()
                        Self.canvasDrag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { e in
                            guard let c = AppActions.canvas, e.window === c.window else { return e }
                            if e.type == .leftMouseDragged { place(c.viewToDoc(c.convert(e.locationInWindow, from: nil))) } else { Self.endCanvasDrag() }
                            return e
                        }
                    }
                    if !CanvasSampler.shared.isArmed { Self.endCanvasDrag() }
                    if CanvasSampler.shared.isArmed { AppModel.shared.setStatus("Click in the image to place the filter's centre") }
                }
            }
        }
        .onDisappear { CanvasSampler.shared.disarm(Self.samplerToken); Self.endCanvasDrag() }
    }

    /// Event monitor while the centre is dragged on the canvas.
    nonisolated(unsafe) static var canvasDrag: Any?
    static func endCanvasDrag() {
        if let m = canvasDrag { NSEvent.removeMonitor(m) }
        canvasDrag = nil
    }

    func setMode(_ m: FilterCenterMode) {
        if m == .custom { if f.centerMode != .custom { f.centerMode = .custom }; return }   // custom starts where the centre is now
        f.resolveCenter(ctx, mode: m)
    }

    /// Thumbnail geometry: scale and size of the document inside `thumbBox`.
    var fit: (scale: CGFloat, size: CGSize) {
        let w = CGFloat(max(1, ctx.canvasWidth)), h = CGFloat(max(1, ctx.canvasHeight))
        let s = min(Self.thumbBox.width / w, Self.thumbBox.height / h)
        return (s, CGSize(width: max(1, w * s), height: max(1, h * s)))
    }

    @ViewBuilder var thumb: some View {
        let (s, size) = fit
        let c = f.centerPixel(canvasWidth: ctx.canvasWidth, canvasHeight: ctx.canvasHeight)
        let p = CGPoint(x: CGFloat(c.x) * s, y: CGFloat(c.y) * s)
        let box = f.centerBox
        let bw = CGFloat(box.width * ctx.canvasWidth) * s, bh = CGFloat(box.height * ctx.canvasHeight) * s
        let radius = f.kind.params.contains { $0.key == "radius" } ? CGFloat(f.value("radius")) * min(bw, bh) : 0
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(white: 0.18))
            if let t = thumbnail { Image(decorative: t, scale: 1).resizable().interpolation(.medium).frame(width: size.width, height: size.height) }
            Canvas { g, _ in
                if f.centerMode == .object || f.centerMode == .selection {
                    let r = CGRect(x: p.x - bw / 2, y: p.y - bh / 2, width: bw, height: bh)
                    g.stroke(Path(r), with: .color(.white.opacity(0.55)), style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if radius > 1 {
                    let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                    g.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.5)), lineWidth: 2.5)
                    g.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.85)), lineWidth: 1)
                }
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 8, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 8, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 8)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 8))
                g.stroke(cross, with: .color(.black.opacity(0.7)), lineWidth: 3)
                g.stroke(cross, with: .color(Theme.accent), lineWidth: 1.5)
                g.stroke(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white), lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 0.5))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let x = clamp(Double(v.location.x / s), 0, ctx.canvasWidth), y = clamp(Double(v.location.y / s), 0, ctx.canvasHeight)
            f.setCustomCenter(x: x, y: y, canvasWidth: ctx.canvasWidth, canvasHeight: ctx.canvasHeight)
        })
        .help("Drag to place the centre")
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Small image of what the dialog's document looks like (before the filter), for placing the centre.
    static func thumbnail(_ st: DocumentState) -> CGImage? {
        let w = CGFloat(max(1, st.width)), h = CGFloat(max(1, st.height))
        let s = min(thumbBox.width / w, thumbBox.height / h, 1)
        let size = CGSize(width: max(1, (w * s).rounded()), height: max(1, (h * s).rounded()))
        let img = Compositor.shared.composite(st)
            .composited(over: CIImage.color(RGBA(gray: 0.85), CGRect(x: 0, y: 0, width: w, height: h)))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        return RenderEngine.cgImage(img, rect: CGRect(origin: .zero, size: size))
    }
}
