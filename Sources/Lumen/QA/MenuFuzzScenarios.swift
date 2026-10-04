import AppKit
import CoreImage
import ImageCratCore

/// A baseline application state the fuzz driver rebuilds before every item.
struct FuzzScenario {
    let name: String
    /// 0: every menu item, dialog (Cancel, OK), panel, tool and key. 1: also fuzzes every dialog / panel control.
    /// 2: also closes / switches / undoes the document under every open dialog.
    var depth = 0
    let build: () -> Void
    var core: Bool { depth >= 1 }
}

/// Files handed out by scripted open panels (created once per output folder).
enum FuzzFixtures {
    static var dir: URL { MenuFuzz.outDir.appendingPathComponent("fixtures") }
    static var png: URL { dir.appendingPathComponent("image.png") }
    static var movie: URL { dir.appendingPathComponent("movie.mp4") }

    static func ensure() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dir.appendingPathComponent(".done").path) { return }
        var st = SelfTest.baseState(320, 240)
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 60, y: 50, width: 150, height: 110)))
        try? DocumentIO.export(st, to: png, format: .png, quality: 1, scale: 1)
        try? DocumentIO.export(st, to: dir.appendingPathComponent("photo.jpg"), format: .jpeg, quality: 0.9, scale: 1)
        try? DocumentIO.export(st, to: dir.appendingPathComponent("scan.tiff"), format: .tiff, quality: 1, scale: 1)
        try? DocumentIO.export(SelfTest.baseState(200, 150), to: dir.appendingPathComponent("other.png"), format: .png, quality: 1, scale: 1)
        for n in ["a", "b", "c"] {
            var s = SelfTest.baseState(160, 120)
            s.layers.append(SelfTest.shapeLayer(CGRect(x: 20 + 10 * n.count, y: 20, width: 80, height: 60)))
            try? DocumentIO.export(s, to: dir.appendingPathComponent("folder/\(n).png"), format: .png, quality: 1, scale: 1)
        }
        let d = Document(state: st, name: "layers")
        try? DocumentIO.saveNative(d, to: dir.appendingPathComponent("layers.imagecrat"))
        try? PSDWriter.write(st, to: dir.appendingPathComponent("layers.psd"))
        // a short movie for the video-layer scenario
        var vs = SelfTest.baseState(160, 120)
        let shape = SelfTest.shapeLayer(CGRect(x: 20, y: 20, width: 60, height: 50))
        vs.layers.append(shape)
        var tl = VideoTimeline(duration: 1, frameRate: 10)
        var tr = LayerTrack(layerID: shape.id, duration: 1)
        tr.setKeys(.position, [Keyframe(time: 0, value: .point(CGPoint(x: 40, y: 40))), Keyframe(time: 1, value: .point(CGPoint(x: 120, y: 80)))])
        tl.tracks = [tr]
        vs.videoTimeline = tl
        try? VideoRenderer.writeMovie(vs, to: movie, settings: VideoRenderSettings())
        try? "name,title\nA,First\nB,Second\n".write(to: dir.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        try? "plain text".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        fm.createFile(atPath: dir.appendingPathComponent(".done").path, contents: nil)
    }
}

enum FuzzScenarios {
    static let W = 320, H = 240

    static var names: [String] { all.map(\.name) }
    static func named(_ n: String) -> FuzzScenario? { all.first { $0.name == n } }

    // MARK: Building blocks

    static func painted(_ name: String = "Paint", w: Int = W, h: Int = H, color: RGBA = RGBA(hex: "E94F37")!) -> Layer {
        let buf = PixelBuffer(width: w, height: h)
        buf.context.setFillColor(color.cgColor)
        buf.context.fillEllipse(in: CGRect(x: Double(w) * 0.2, y: Double(h) * 0.2, width: Double(w) * 0.5, height: Double(h) * 0.5))
        buf.context.setFillColor(RGBA(hex: "2E86DE")!.cgColor)
        buf.context.fill(CGRect(x: Double(w) * 0.55, y: Double(h) * 0.5, width: Double(w) * 0.25, height: Double(h) * 0.3))
        buf.markDirty()
        return Layer.raster(name: name, buffer: buf)
    }

    static func text(_ s: String = "Fuzz Text") -> Layer {
        var t = TextContent()
        t.text = s; t.fontSize = 32; t.position = CGPoint(x: 40, y: 60); t.color = .black
        return Layer(name: "Type", content: .text(t))
    }

    static func shape() -> Layer { SelfTest.shapeLayer(CGRect(x: 70, y: 50, width: 160, height: 110)) }

    static func smartImage() -> Layer {
        let src = painted(w: 200, h: 150)
        let so = SmartObjectContent(source: .image(src.raster!.buffer), quad: Quad(rect: CGRect(x: 50, y: 40, width: 200, height: 150)), sourceName: "Embedded")
        return Layer(name: "Smart Image", content: .smartObject(so))
    }

    static func smartDocument() -> Layer {
        var inner = DocumentState(width: 200, height: 150)
        inner.layers = [painted(w: 200, h: 150), SelfTest.shapeLayer(CGRect(x: 20, y: 20, width: 80, height: 60))]
        let so = SmartObjectContent(source: .document(inner), quad: Quad(rect: CGRect(x: 60, y: 45, width: 200, height: 150)), sourceName: "Embedded Doc")
        return Layer(name: "Smart Doc", content: .smartObject(so))
    }

    static func rectSelection(w: Int = W, h: Int = H) -> PixelBuffer {
        let m = PixelBuffer(width: w, height: h, gray: 0)
        m.context.setFillColor(gray: 1, alpha: 1)
        m.context.fill(CGRect(x: Double(w) * 0.25, y: Double(h) * 0.25, width: Double(w) * 0.45, height: Double(h) * 0.4))
        m.markDirty()
        return m
    }

    /// Opens a document made of a gradient background plus `layers` (added as one undoable step, the last one active).
    @discardableResult
    static func open(_ layers: [Layer] = [], w: Int = W, h: Int = H, name: String = "Fuzz", select: [UUID]? = nil,
                     selection: Bool = false, prepare: ((inout DocumentState) -> Void)? = nil) -> Document {
        let st = SelfTest.baseState(w, h)
        let d = Document(state: st, name: name)
        AppModel.shared.add(d)
        AppActions.canvas?.document = d
        var s = d.state
        s.layers.append(contentsOf: layers)
        if selection { s.selection = rectSelection(w: w, h: h) }
        prepare?(&s)
        d.state = s
        if let last = layers.last {
            d.activeLayerID = last.id
            d.selectedLayerIDs = [last.id]
        }
        if let sel = select {
            d.selectedLayerIDs = Set(sel)
            d.activeLayerID = sel.last
        }
        d.commit("Fuzz Setup")
        return d
    }

    static var canvas: CanvasView? { AppActions.canvas }

    // MARK: Scenario list

    static let all: [FuzzScenario] = {
        var s: [FuzzScenario] = []
        let deep: Set<String> = ["raster", "text"]
        func add(_ name: String, core: Bool = false, _ build: @escaping () -> Void) {
            s.append(FuzzScenario(name: name, depth: deep.contains(name) ? 2 : (core ? 1 : 0), build: build))
        }

        add("nodoc", core: true) {}
        add("empty", core: true) {
            AppActions.newDocument(width: W, height: H, resolution: 72, background: .white, name: "Empty")
            AppActions.canvas?.document = AppModel.shared.activeDocument
        }
        add("transparent") {
            AppActions.newDocument(width: W, height: H, resolution: 72, background: nil, name: "Transparent")
            AppActions.canvas?.document = AppModel.shared.activeDocument
        }
        add("raster", core: true) { open([painted()]) }
        add("text", core: true) { open([text()]) }
        add("shape", core: true) { open([shape()]) }
        add("smart_embedded", core: true) { open([smartImage()]) }
        add("smart_document") { open([smartDocument()]) }
        add("smart_linked") {
            let d = open([painted()])
            AppActions.placeLinked(FuzzFixtures.png)
            _ = d
        }
        add("fill") {
            open([painted()])
            AppActions.newFillLayer(.color(RGBA(hex: "27AE60")!), name: "Color Fill")
        }
        add("gradient_fill") {
            open([painted()])
            AppActions.newFillLayer(.gradient(GradientFill(gradient: .twoColor(.black, .white))), name: "Gradient Fill")
        }
        add("adjustment", core: true) {
            open([painted()])
            AppActions.newAdjustmentLayer(.levels)
        }
        add("group", core: true) {
            let a = painted(), b = text()
            var g = Layer(name: "Group 1", content: .group(GroupContent(children: [a, b], isExpanded: true)))
            g.blendMode = .passThrough
            open([g])
        }
        add("empty_group") {
            open([painted(), Layer(name: "Group 1", content: .group(GroupContent()))])
        }
        add("artboard") {
            open([painted()])
            AppActions.newArtboard()
            if let d = AppActions.doc, let ab = d.activeLayerID {
                d.state.insertLayer(shape(), above: ab, inside: true)
                d.commit("Fuzz Setup 2")
                d.selectLayer(ab)
            }
        }
        add("frame") {
            let p = painted()
            let d = open([p])
            FrameSupport.createFrame(d, rect: CGRect(x: 60, y: 40, width: 180, height: 140), ellipse: false, wrapActive: true)
        }
        add("generative") {
            let p = painted("Generative Layer")
            let d = open([p])
            var info = GenerativeLayerInfo()
            info.prompt = "a red ball"; info.providerID = "openai"; info.modelID = "gpt-image-1"
            info.rect = IRect(x: 0, y: 0, width: W, height: H)
            info.variations = [p.raster!.buffer, painted(color: RGBA(hex: "8E44AD")!).raster!.buffer]
            info.seeds = [1, 2]
            d.state.generative[p.id] = info
            d.commit("Fuzz Setup 2")
        }
        add("video_layer") {
            let d = open([painted()])
            _ = try? VideoLayerImport.addVideoLayer(FuzzFixtures.movie, to: d)
            TimelineController.shared.isPanelVisible = true
        }
        add("video_timeline") {
            let sh = shape()
            open([sh]) { st in
                var tl = VideoTimeline(duration: 2, frameRate: 10)
                var tr = LayerTrack(layerID: sh.id, duration: 2)
                tr.setKeys(.position, [Keyframe(time: 0, value: .point(CGPoint(x: 60, y: 120))), Keyframe(time: 2, value: .point(CGPoint(x: 260, y: 120)))])
                tr.setKeys(.opacity, [Keyframe(time: 0, interpolation: .hold, value: .number(1)), Keyframe(time: 1.5, value: .number(0.4))])
                tl.tracks = [tr]
                st.videoTimeline = tl
            }
            TimelineController.shared.isPanelVisible = true
        }
        add("frame_animation") {
            let p = painted()
            let d = open([p])
            let tl = TimelineController.shared
            tl.createAnimation(d)
            tl.newFrame(d)
            d.updateLayer(p.id) { $0.translate(dx: 40, dy: 10) }
            d.commit("Move")
            tl.newFrame(d)
            tl.isPanelVisible = true
        }
        add("locked") { var p = painted(); p.locks.all = true; open([p]) }
        add("hidden") { var p = painted(); p.isVisible = false; open([p]) }
        add("mask_target", core: true) {
            var p = painted()
            var m = LayerMask.reveal(width: W, height: H)
            m.buffer.context.setFillColor(gray: 0, alpha: 1)
            m.buffer.context.fill(CGRect(x: 0, y: 0, width: 120, height: 240))
            m.buffer.markDirty()
            p.mask = m
            let d = open([p])
            d.editTarget = .mask
        }
        add("multi_select", core: true) {
            let a = painted(), b = text(), c = shape()
            open([a, b, c], select: [a.id, b.id, c.id])
        }
        add("none_selected", core: true) {
            let d = open([painted(), text()])
            d.activeLayerID = nil
            d.selectedLayerIDs = []
        }
        add("no_layers") {
            let d = open([])
            d.state.layers = []
            d.activeLayerID = nil
            d.selectedLayerIDs = []
            d.commit("Delete Layer")
        }
        add("selection", core: true) { open([painted()], selection: true) }
        add("selection_text") { open([text()], selection: true) }
        add("selection_smart") { open([smartImage()], selection: true) }
        add("quickmask") {
            let d = open([painted()], selection: true)
            d.quickMask = true
        }
        add("text_editing", core: true) {
            let t = text()
            open([t])
            AppModel.shared.tool = .text
            if let tt = canvas?.tool(for: .text) as? TextTool {
                tt.beginEditing(t.id, isNew: false)
                tt.testType("Hi")
            }
        }
        add("transform_pending", core: true) {
            let p = painted()
            open([p])
            AppModel.shared.tool = .move
            if let mt = canvas?.tool(for: .move) as? MoveTool {
                mt.startTransform()
                if let s = mt.session {
                    let o = s.quad.tl
                    s.quad = s.quad.mapped { CGPoint(x: o.x + ($0.x - o.x) * 1.3, y: o.y + ($0.y - o.y) * 0.8) }
                    s.updatePreview()
                }
            }
        }
        add("transform_pending_text") {
            let t = text()
            open([t])
            AppModel.shared.tool = .move
            if let mt = canvas?.tool(for: .move) as? MoveTool {
                mt.startTransform()
                if let s = mt.session {
                    let o = s.quad.tl
                    s.quad = s.quad.mapped { CGPoint(x: o.x + ($0.x - o.x) * 1.5, y: o.y + ($0.y - o.y) * 1.5) }
                    s.updatePreview()
                }
            }
        }
        add("warp_pending") {
            open([painted()])
            AppModel.shared.tool = .move
            AppActions.warp()
        }
        add("crop_pending", core: true) {
            open([painted()])
            AppModel.shared.tool = .crop
            if let c = canvas {
                let t = c.tool(for: .crop)
                t.activate()
                func ev(_ p: CGPoint) -> ToolEvent { ToolEvent(doc: p, view: c.docToView(p), pressure: 1, modifiers: [], clickCount: 1, isTablet: false) }
                t.mouseDown(ev(CGPoint(x: W, y: H)))
                t.mouseDragged(ev(CGPoint(x: Double(W) * 0.7, y: Double(H) * 0.75)))
                t.mouseUp(ev(CGPoint(x: Double(W) * 0.7, y: Double(H) * 0.75)))
            }
        }
        add("cmyk", core: true) { open([painted(), text()]); AppActions.convertMode(.cmyk) }
        add("lab") { open([painted(), text()]); AppActions.convertMode(.lab) }
        add("grayscale") { open([painted(), text()]); AppActions.convertMode(.grayscale) }
        add("indexed") { let d = open([painted()]); ColorModes.convertToIndexed(d, IndexedOptions()) }
        add("bitmap") {
            let d = open([painted()])
            AppActions.convertMode(.grayscale)
            ColorModes.convertToBitmap(d, BitmapOptions())
        }
        add("duotone") {
            let d = open([painted()])
            AppActions.convertMode(.grayscale)
            ColorModes.convertToDuotone(d, DuotoneSettings.presets.last!.1)
        }
        add("multichannel") { let d = open([painted()]); ColorModes.convertToMultichannel(d) }
        add("bit16") { open([painted(), text()]); AppActions.setBitDepth(.sixteen) }
        add("bit32") { open([painted()]); AppActions.setBitDepth(.thirtyTwo) }
        add("tiny", core: true) { open([painted(w: 1, h: 1)], w: 1, h: 1) }
        add("tiny_selection") { open([painted(w: 1, h: 1)], w: 1, h: 1) { st in st.selection = PixelBuffer(width: 1, height: 1, gray: 255) } }
        add("wide") { open([painted(w: 6000, h: 3)], w: 6000, h: 3) }
        add("tall") { open([painted(w: 2, h: 3000)], w: 2, h: 3000) }
        add("smart_child") {
            let so = smartDocument()
            let d = open([so])
            AppActions.editSmartContents(so.id)
            AppActions.canvas?.document = AppModel.shared.activeDocument
            _ = d
        }
        add("two_docs", core: true) {
            open([painted()], name: "First")
            open([text()], w: 200, h: 300, name: "Second")
        }
        add("paths") {
            let d = open([painted()])
            d.state.paths = [NamedPath(name: "Work Path", path: VectorPath.ellipse(CGRect(x: 60, y: 50, width: 150, height: 120)))]
            d.activePathID = d.state.paths[0].id
            d.state.guides = [Guide(isVertical: true, position: 100), Guide(isVertical: false, position: 80)]
            d.commit("Fuzz Setup 2")
        }
        add("fx_masks") {
            var p = painted()
            p.effects.dropShadow.enabled = true; p.effects.stroke.enabled = true; p.effects.bevel.enabled = true
            p.vectorMask = VectorPath.ellipse(CGRect(x: 40, y: 30, width: 220, height: 170))
            p.mask = LayerMask.reveal(width: W, height: H)
            var t = text(); t.isClipped = true
            open([p, t])
        }
        // A dialog is already open (dialogs are in-window overlays, so the menu bar stays usable).
        add("dialog_filter") {
            open([painted()])
            AppModel.shared.dialog = .filter(.gaussianBlur, smartLayer: nil, editingFilter: nil)
        }
        add("dialog_adjust") {
            open([painted()])
            AppModel.shared.dialog = .adjustment(.levels)
        }
        add("dialog_layerstyle") {
            let p = painted()
            open([p])
            AppModel.shared.dialog = .layerStyle(p.id)
        }
        add("dialog_smartfilter") {
            let so = smartImage()
            open([so])
            AppModel.shared.dialog = .filter(.gaussianBlur, smartLayer: so.id, editingFilter: nil)
        }
        add("dialog_selectmask") {
            open([painted()], selection: true)
            AppModel.shared.dialog = .selectAndMask
        }
        add("dialog_liquify") {
            open([painted()])
            AppModel.shared.dialog = .liquify
        }
        add("dialog_imagesize") {
            open([painted()])
            AppModel.shared.dialog = .imageSize
        }
        // unusual documents first: that is where commands break
        let first = ["tiny", "tiny_selection", "no_layers", "wide", "tall", "none_selected", "bitmap", "indexed", "duotone", "multichannel", "lab", "grayscale",
                     "cmyk", "bit16", "bit32", "text_editing", "transform_pending", "transform_pending_text", "warp_pending", "crop_pending", "quickmask",
                     "smart_child", "video_layer", "video_timeline", "frame_animation", "generative", "artboard", "frame", "locked", "hidden", "empty_group"]
        return s.sorted { a, b in
            let ia = first.firstIndex(of: a.name) ?? first.count, ib = first.firstIndex(of: b.name) ?? first.count
            return ia < ib
        }
    }()
}
