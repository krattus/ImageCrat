import SwiftUI
import CoreImage
import ImageCratCore

// MARK: - Clone Source panel state (5 sources with offset / scale / rotation / flip and a source overlay)

struct CloneSourceSlot: Equatable {
    /// Source point (doc coordinates of the source document).
    var point: CGPoint? = nil
    var docID: UUID? = nil
    var docName = ""
    /// Photoshop's Offset X/Y: destination anchor − source point. Set when painting starts (kept while Aligned).
    var offset: CGPoint? = nil
    var scaleW = 100.0
    var scaleH = 100.0
    var linked = true
    var rotation = 0.0      // degrees, clockwise on screen
    var flipH = false
    var flipV = false

    var hasTransform: Bool { scaleW != 100 || scaleH != 100 || rotation != 0 || flipH || flipV }

    /// Linear part A (source → destination): the cloned content is scaled, flipped and rotated by A.
    var linear: CGAffineTransform {
        let sx = CGFloat(scaleW / 100) * (flipH ? -1 : 1), sy = CGFloat(scaleH / 100) * (flipV ? -1 : 1)
        return CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation * .pi / 180)))
    }

    /// Maps a destination doc point to the source doc point it copies from.
    var destToSource: CGAffineTransform? {
        guard let s = point, let off = offset else { return nil }
        let d0 = s + off
        let a = linear
        guard abs(a.a * a.d - a.b * a.c) > 1e-9 else { return nil }
        // x ↦ s + A⁻¹(x − d0)
        return CGAffineTransform(translationX: -d0.x, y: -d0.y).concatenating(a.inverted()).concatenating(CGAffineTransform(translationX: s.x, y: s.y))
    }
}

@Observable
final class CloneSources {
    static let shared = CloneSources()

    var slots = Array(repeating: CloneSourceSlot(), count: 5)
    var active = 0
    var showOverlay = true
    var overlayOpacity = 100.0
    var clipped = true
    var autoHide = false
    var invert = false

    var slot: CloneSourceSlot {
        get { slots[active] }
        set { slots[active] = newValue }
    }

    /// Option-click: define the active source.
    func define(_ p: CGPoint?, doc: Document?) {
        var s = slot
        s.point = p
        s.docID = doc?.id
        s.docName = doc?.name ?? ""
        s.offset = nil
        slot = s
    }

    /// Clone tool's offset convention (source − destination, identity transform).
    var toolOffset: CGPoint? {
        get { slot.offset.map { -$0 } }
        set { slots[active].offset = newValue.map { -$0 } }
    }

    var needsTransform: Bool { slot.hasTransform }

    func sourcePoint(forDest p: CGPoint) -> CGPoint? { slot.destToSource.map { p.applying($0) } }

    /// Pixels of a source defined in another open document (composite, canvas-size at origin zero).
    func externalSource(for current: Document) -> (PixelBuffer, IPoint)? {
        guard let id = slot.docID, id != current.id, let d = AppModel.shared.documents.first(where: { $0.id == id }) else { return nil }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let img = Compositor.shared.composite(d.committedState).cropped(to: sp.ciCanvas)
        return (RenderEngine.renderBuffer(img, docRect: d.state.canvasRect, space: sp), .zero)
    }

    // MARK: Overlay

    private var overlayKey = ""
    private var overlayImage: CGImage?

    private func sourceImage() -> CGImage? {
        guard let id = slot.docID ?? AppActions.doc?.id, let d = AppModel.shared.documents.first(where: { $0.id == id }) ?? AppActions.doc else { return nil }
        let key = "\(d.id)-\(d.revision)-\(invert)"
        if key == overlayKey, let i = overlayImage { return i }
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        var img = Compositor.shared.composite(d.committedState).cropped(to: sp.ciCanvas)
        if invert { img = img.applyingFilter("CIColorInvert") }
        overlayImage = RenderEngine.cgImage(img, rect: sp.ciCanvas)
        overlayKey = key
        return overlayImage
    }

    /// Draws the transformed source under the brush (or everywhere when not clipped).
    func drawOverlay(_ ctx: CGContext, canvas: CanvasView, brushSize: Double, painting: Bool) {
        guard showOverlay, !(autoHide && painting), let m = canvas.lastMouseView else { return }
        let cursor = canvas.viewToDoc(m)
        var s = slot
        guard s.point != nil else { return }
        if s.offset == nil || !AppModel.shared.cloneAligned { s.offset = cursor - s.point! }
        guard let t = s.destToSource, let img = sourceImage() else { return }
        let sourceToDest = t.inverted()
        ctx.saveGState()
        if clipped {
            let r = CGFloat(brushSize) * canvas.zoom / 2
            ctx.addEllipse(in: CGRect(x: m.x - r, y: m.y - r, width: 2 * r, height: 2 * r))
            ctx.clip()
        }
        ctx.setAlpha(CGFloat(overlayOpacity / 100) * (clipped ? 1 : 0.5))
        ctx.concatenate(sourceToDest.concatenating(canvas.docToViewTransform))
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: 0, y: CGFloat(img.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.restoreGState()
    }
}

extension PaintStroke {
    /// Clone dab whose source pixels are sampled through an affine map (destination doc point → source doc point).
    func transformedDab(mask: CGImage, at p: CGPoint, source: PixelBuffer, sourceOrigin: IPoint, destToSource T: CGAffineTransform, alpha: Double) {
        let c = toBuffer(p)
        let w = CGFloat(mask.width), h = CGFloat(mask.height)
        let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let docR = r.offsetBy(dx: CGFloat(origin.x), dy: CGFloat(origin.y))
        let srcDoc = CGRect.bounding(docR.corners.map { $0.applying(T) }).insetBy(dx: -3, dy: -3)
        let srcBuf = IRect(enclosing: srcDoc.offsetBy(dx: -CGFloat(sourceOrigin.x), dy: -CGFloat(sourceOrigin.y))).intersection(source.bounds)
        guard !srcBuf.isEmpty, let sub = source.unsafeImage(rect: srcBuf) else { return }
        // source-buffer q → stroke-buffer b = T⁻¹(q + sourceOrigin) − origin
        let M = CGAffineTransform(translationX: CGFloat(sourceOrigin.x), y: CGFloat(sourceOrigin.y))
            .concatenating(T.inverted())
            .concatenating(CGAffineTransform(translationX: -CGFloat(origin.x), y: -CGFloat(origin.y)))
        let ctx = strokeBuf.context
        ctx.saveGState()
        strokeBuf.clip(toMask: mask, in: r)
        ctx.concatenate(M)
        strokeBuf.drawImage(sub, in: srcBuf.cgRect, alpha: CGFloat(alpha))
        ctx.restoreGState()
        addDirty(IRect(enclosing: r))
    }
}

// MARK: - Panel

struct CloneSourcePanel: View {
    @Bindable var cs = CloneSources.shared
    @Bindable var app = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { i in
                        Button { cs.active = i } label: {
                            Image(systemName: cs.slots[i].point == nil ? "seal" : "seal.fill")
                                .font(.system(size: 15)).frame(minWidth: 26, idealWidth: 34, maxWidth: 34).frame(height: 28)   // (narrower in a narrow column)
                                .background(RoundedRectangle(cornerRadius: 4).fill(cs.active == i ? Theme.accent.opacity(0.35) : Theme.fieldBG))
                        }
                        .buttonStyle(.plain)
                        .help(tr(cs.slots[i].point.map { p in "Clone Source \(i + 1): \(cs.slots[i].docName) (\(Int(p.x)), \(Int(p.y)))" } ?? "Clone Source \(i + 1): Option-click with the Clone Stamp or Healing Brush to set"))
                    }
                }
                Text(tr(cs.slot.point.map { "Source: \(cs.slot.docName.isEmpty ? "Untitled" : cs.slot.docName) @ \(Int($0.x)), \(Int($0.y))" } ?? "Option-click in an image to set the source."))
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Caption("Offset")
                HStack {
                    NumberField(label: "X", value: Binding(get: { Double(cs.slot.offset?.x ?? 0) }, set: { v in cs.slot.offset = CGPoint(x: CGFloat(v), y: cs.slot.offset?.y ?? 0) }), width: 54)
                    NumberField(label: "Y", value: Binding(get: { Double(cs.slot.offset?.y ?? 0) }, set: { v in cs.slot.offset = CGPoint(x: cs.slot.offset?.x ?? 0, y: CGFloat(v)) }), width: 54)
                }
                WrappingHStack {   // (H goes under W in a narrow column)
                    HStack {
                        Text("W").foregroundStyle(Theme.textDim)
                        NumberField(label: "", value: Binding(get: { cs.slot.scaleW }, set: { v in cs.slot.scaleW = clamp(v, 1, 1000); if cs.slot.linked { cs.slot.scaleH = cs.slot.scaleW } }), width: 48, format: "%.1f")
                        Text("%").foregroundStyle(Theme.textFaint)
                    }
                    HStack {
                        Button { cs.slot.linked.toggle() } label: { Image(systemName: cs.slot.linked ? "link" : "link.badge.plus") }.buttonStyle(.plain).help("Maintain aspect ratio")
                        Text("H").foregroundStyle(Theme.textDim)
                        NumberField(label: "", value: Binding(get: { cs.slot.scaleH }, set: { v in cs.slot.scaleH = clamp(v, 1, 1000); if cs.slot.linked { cs.slot.scaleW = cs.slot.scaleH } }), width: 48, format: "%.1f")
                        Text("%").foregroundStyle(Theme.textFaint)
                    }
                }
                WrappingHStack {
                    HStack {
                        NumberField(label: "Angle", value: Binding(get: { cs.slot.rotation }, set: { cs.slot.rotation = $0.truncatingRemainder(dividingBy: 360) }), width: 48, format: "%.1f")
                        Text("°").foregroundStyle(Theme.textFaint)
                    }
                    IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal", active: cs.slot.flipH) { cs.slot.flipH.toggle() }
                    IconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical", active: cs.slot.flipV) { cs.slot.flipV.toggle() }
                    IconButton(symbol: "arrow.counterclockwise", help: "Reset Transform") {
                        cs.slot.scaleW = 100; cs.slot.scaleH = 100; cs.slot.rotation = 0; cs.slot.flipH = false; cs.slot.flipV = false
                    }
                }
                Divider()
                Toggle2(label: "Show Overlay", on: $cs.showOverlay)
                ValueSlider(label: "Opacity", value: $cs.overlayOpacity, range: 0...100, unit: "%", labelWidth: 84)
                WrappingHStack {
                    Toggle2(label: "Clipped", on: $cs.clipped)
                    Toggle2(label: "Auto Hide", on: $cs.autoHide)
                    Toggle2(label: "Invert", on: $cs.invert)
                }
                Divider()
                Toggle2(label: "Aligned", on: $app.cloneAligned)
                Toggle2(label: "Sample All Layers", on: $app.cloneSampleAll)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum CloneSourcesModule {
    static func register() {
        PanelRegistry.register(PanelRegistry.Def(id: "cloneSource", title: "Clone Source") { AnyView(CloneSourcePanel()) })
    }
}
