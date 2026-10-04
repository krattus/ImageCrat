import AppKit
import CoreImage
import ImageCratCore

/// Documents for the tool robot: one per "active layer kind" of the test matrix.
struct QAFixture {
    var name: String
    var state: DocumentState
    /// Layer made active (nil = no layer selected).
    var active: UUID?
    var selected: [UUID] = []
    var editMask = false
    var quickMask = false
    /// Layers that must not change at all (fully locked / hidden when they are the target).
    var frozen: [UUID] = []
    /// Layers whose position (content bounds) must not change.
    var pinned: [UUID] = []
    /// Layers whose alpha must not change (transparency lock).
    var alphaLocked: [UUID] = []

    func apply(to d: Document) {
        d.activeLayerID = active
        d.selectedLayerIDs = Set(selected.isEmpty ? (active.map { [$0] } ?? []) : selected)
        d.editTarget = editMask ? .mask : .content
        d.quickMask = quickMask
    }
}

enum QAFixtures {
    static let W = 240, H = 160
    /// Where the target layer's content sits in every fixture.
    static let box = CGRect(x: 60, y: 40, width: 100, height: 70)

    static func background(_ w: Int = W, _ h: Int = H) -> Layer {
        let bg = PixelBuffer(width: w, height: h)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "8EC5FC")!.cgColor, RGBA(hex: "E0C3FC")!.cgColor] as CFArray, locations: [0, 1])!
        bg.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        // a few hard features so edge / flood tools have something to find
        bg.context.setFillColor(RGBA(hex: "1B1F3A")!.cgColor)
        bg.context.fill(CGRect(x: CGFloat(w) * 0.72, y: CGFloat(h) * 0.12, width: CGFloat(w) * 0.2, height: CGFloat(h) * 0.25))
        bg.context.setFillColor(RGBA(hex: "E02020")!.cgColor)
        bg.context.fillEllipse(in: CGRect(x: CGFloat(w) * 0.08, y: CGFloat(h) * 0.62, width: CGFloat(w) * 0.16, height: CGFloat(h) * 0.24))
        bg.markDirty()
        return Layer.raster(name: "Background", buffer: bg)
    }

    static func base(_ w: Int = W, _ h: Int = H) -> DocumentState {
        var st = DocumentState(width: w, height: h)
        st.layers = [background(w, h)]
        return st
    }

    /// A pixel layer with an opaque two-colour block at `r` (rest transparent).
    static func rasterLayer(_ name: String = "Pixels", _ r: CGRect = box, canvas: (Int, Int) = (W, H), origin: IPoint = .zero) -> Layer {
        let buf = PixelBuffer(width: canvas.0, height: canvas.1)
        buf.context.setFillColor(RGBA(hex: "2E86AB")!.cgColor)
        buf.context.fill(r.offsetBy(dx: CGFloat(-origin.x), dy: CGFloat(-origin.y)))
        buf.context.setFillColor(RGBA(hex: "F6AE2D")!.cgColor)
        buf.context.fill(CGRect(x: r.minX + r.width * 0.55 - CGFloat(origin.x), y: r.minY + r.height * 0.2 - CGFloat(origin.y), width: r.width * 0.3, height: r.height * 0.5))
        buf.markDirty()
        return Layer.raster(name: name, buffer: buf, origin: origin)
    }

    static func textLayer(_ s: String = "Qa", at p: CGPoint = CGPoint(x: 62, y: 44), size: Double = 44) -> Layer {
        var t = TextContent()
        t.text = s; t.fontName = "Helvetica-Bold"; t.fontSize = size; t.position = p; t.color = RGBA(hex: "1B1F3A")!
        return Layer(name: "Text", content: .text(t))
    }

    static func shapeLayer(_ r: CGRect = box, _ c: RGBA = RGBA(hex: "E94F37")!) -> Layer {
        Layer(name: "Shape", content: .shape(ShapeContent(geometry: .rectangle(r, cornerRadius: 0), fill: .color(c))))
    }

    static func checker(_ w: Int, _ h: Int, cell: Int = 10) -> PixelBuffer {
        let buf = PixelBuffer(width: w, height: h)
        for y in stride(from: 0, to: h, by: cell) {
            for x in stride(from: 0, to: w, by: cell) {
                buf.context.setFillColor(((x / cell + y / cell) % 2 == 0 ? RGBA(hex: "2E4057")! : RGBA(hex: "F6AE2D")!).cgColor)
                buf.context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        buf.markDirty()
        return buf
    }

    static func smartLayer(_ r: CGRect = box, linked: URL? = nil) -> Layer {
        var so = SmartObjectContent(source: .image(checker(Int(r.width), Int(r.height))), quad: Quad(rect: r), sourceName: "checker")
        if let u = linked {
            so.linkedURL = u
            so.linkedModified = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
        }
        return Layer(name: linked == nil ? "Smart" : "Linked", content: .smartObject(so))
    }

    static func rectSelection(_ r: CGRect, _ w: Int = W, _ h: Int = H) -> PixelBuffer { SelectionOps.rectMask(r, width: w, height: h) }

    /// Every active-layer kind of the matrix. `out` receives the linked smart object's file.
    static func all(_ out: URL) -> [QAFixture] {
        var f: [QAFixture] = []
        func add(_ name: String, _ top: [Layer], active: UUID?, _ tweak: (inout QAFixture) -> Void = { _ in }) {
            var st = base()
            st.layers += top
            var fx = QAFixture(name: name, state: st, active: active)
            tweak(&fx)
            f.append(fx)
        }
        // raster
        let r = rasterLayer()
        add("raster", [r], active: r.id)
        // text
        let t = textLayer()
        add("text", [t], active: t.id)
        // shape
        let s = shapeLayer()
        add("shape", [s], active: s.id)
        // smart object (embedded)
        let so = smartLayer()
        add("smart", [so], active: so.id)
        // smart object (linked)
        let linkURL = out.appendingPathComponent("qa_linked_source.png")
        if let png = checker(100, 70).pngData() { try? png.write(to: linkURL) }
        let lso = smartLayer(linked: linkURL)
        add("linked", [lso], active: lso.id)
        // fill layer
        var fill = Layer(name: "Fill", content: .fill(FillContent(paint: .color(RGBA(hex: "27AE60")!))))
        fill.opacity = 0.6
        add("fill", [fill], active: fill.id)
        // adjustment layer
        var adj = AdjustmentSettings(kind: .brightnessContrast)
        adj.brightness = 40
        let al = Layer(name: "Brightness", content: .adjustment(adj))
        add("adjustment", [rasterLayer("Under")] + [al], active: al.id)
        // group
        let g = Layer(name: "Group", content: .group(GroupContent(children: [rasterLayer("In group", CGRect(x: 60, y: 40, width: 50, height: 70)),
                                                                             shapeLayer(CGRect(x: 110, y: 40, width: 50, height: 70))], isExpanded: true)))
        add("group", [g], active: g.id)
        // artboard with a child that pokes out of it (must stay clipped)
        let abChild = rasterLayer("On artboard", CGRect(x: 10, y: 30, width: 150, height: 80))
        let ab = Layer(name: "Artboard 1", content: .group(GroupContent(children: [abChild], isExpanded: true,
                                                                        artboard: Artboard(rect: CGRect(x: 40, y: 20, width: 160, height: 120)))))
        add("artboard", [ab], active: ab.id)
        add("artboard-child", [ab], active: abChild.id)
        // frame
        do {
            var st = base()
            let img = smartLayer(CGRect(x: 40, y: 30, width: 140, height: 100))
            st.layers.append(img)
            let d = Document(state: st, name: "frame")
            d.selectLayer(img.id)
            let fid = FrameSupport.createFrame(d, rect: box, ellipse: false, wrapActive: true)
            f.append(QAFixture(name: "frame", state: d.state, active: fid))
        }
        // hidden layer
        var hidden = rasterLayer("Hidden")
        hidden.isVisible = false
        add("hidden", [hidden], active: hidden.id) { $0.frozen = [hidden.id] }
        // fully locked
        var locked = rasterLayer("Locked")
        locked.locks.all = true
        add("locked-all", [locked], active: locked.id) { $0.frozen = [locked.id] }
        // position locked
        var pos = rasterLayer("Pos locked")
        pos.locks.position = true
        add("locked-position", [pos], active: pos.id) { $0.pinned = [pos.id] }
        // transparency locked
        var tr = rasterLayer("Alpha locked")
        tr.locks.transparency = true
        add("locked-transparency", [tr], active: tr.id) { $0.alphaLocked = [tr.id] }
        // pixels locked
        var px = rasterLayer("Pixels locked")
        px.locks.pixels = true
        add("locked-pixels", [px], active: px.id)
        // mask, editing the mask / the content
        var masked = rasterLayer("Masked")
        var m = LayerMask.reveal(width: W, height: H)
        m.buffer.context.setFillColor(gray: 0, alpha: 1)
        m.buffer.context.fill(CGRect(x: 60, y: 40, width: 30, height: 70))
        m.buffer.markDirty()
        masked.mask = m
        add("mask-target", [masked], active: masked.id) { $0.editMask = true }
        var masked2 = masked.duplicated(newName: "Masked")
        masked2.mask?.isLinked = false
        add("mask-content", [masked], active: masked.id)
        add("mask-unlinked", [masked2], active: masked2.id)
        // vector mask
        var vm = rasterLayer("Vector masked")
        vm.vectorMask = VectorPath.ellipse(box.insetBy(dx: 8, dy: 6))
        add("vector-mask", [vm], active: vm.id)
        // clipped layer
        var clip = rasterLayer("Clipped", CGRect(x: 90, y: 20, width: 100, height: 70))
        clip.isClipped = true
        add("clipped", [shapeLayer(), clip], active: clip.id)
        // layer with effects
        var fx = rasterLayer("Effects")
        fx.effects.dropShadow.enabled = true; fx.effects.dropShadow.distance = 8; fx.effects.dropShadow.size = 6
        fx.effects.stroke.enabled = true; fx.effects.stroke.size = 4; fx.effects.stroke.paint = .color(.white)
        add("effects", [fx], active: fx.id)
        // generative layer
        do {
            // like the GenAI pipeline makes them: the layer holds the selected variation at the generated region
            let first = checker(100, 70)
            let gl = Layer.raster(name: "Generative", buffer: first, origin: IPoint(x: 60, y: 40))
            var st = base()
            st.layers.append(gl)
            var info = GenerativeLayerInfo()
            info.prompt = "qa"; info.rect = IRect(x: 60, y: 40, width: 100, height: 70)
            info.variations = [first, checker(100, 70, cell: 5)]
            st.generative[gl.id] = info
            f.append(QAFixture(name: "generative", state: st, active: gl.id))
        }
        // layer partly outside the canvas (buffer smaller than the canvas, negative origin)
        let off = rasterLayer("Offset", CGRect(x: -30, y: -20, width: 120, height: 100), canvas: (120, 100), origin: IPoint(x: -30, y: -20))
        add("offset", [off], active: off.id)
        // empty layer
        let empty = Layer.raster(name: "Empty", width: W, height: H)
        add("empty", [empty], active: empty.id)
        // nothing selected
        add("no-layer", [rasterLayer()], active: nil)
        // several layers selected, two of them linked
        let link = UUID()
        var a = rasterLayer("A", CGRect(x: 30, y: 30, width: 60, height: 50)), b = shapeLayer(CGRect(x: 120, y: 60, width: 70, height: 60)), c = textLayer("Z", at: CGPoint(x: 100, y: 10), size: 30)
        a.linkID = link; c.linkID = link
        add("multi", [a, b, c], active: b.id) { $0.selected = [a.id, b.id] }
        add("linked-layers", [a, b, c], active: a.id)
        return f
    }

    /// Selection variants (second matrix dimension).
    static func selections() -> [(String, (DocumentState) -> PixelBuffer?, Bool)] {
        [("rect", { st in rectSelection(CGRect(x: 80, y: 50, width: 70, height: 50), st.width, st.height) }, false),
         ("feathered", { st in SelectionOps.feather(rectSelection(CGRect(x: 80, y: 50, width: 70, height: 50), st.width, st.height), radius: 6) }, false),
         ("inverted", { st in SelectionOps.invert(rectSelection(CGRect(x: 80, y: 50, width: 70, height: 50), st.width, st.height)) }, false),
         ("outside-layer", { st in rectSelection(CGRect(x: 180, y: 110, width: 50, height: 40), st.width, st.height) }, false),
         ("quickmask", { st in rectSelection(CGRect(x: 80, y: 50, width: 70, height: 50), st.width, st.height) }, true)]
    }
}
