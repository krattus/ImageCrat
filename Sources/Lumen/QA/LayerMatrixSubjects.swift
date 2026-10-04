import AppKit
import CoreImage
import ImageCratCore

/// A document with one layer (or a small layer stack) under test.
struct QASubject {
    var name: String
    /// Core subjects (one per layer kind / variant) get the full set of pre-transforms; attribute subjects get a few.
    var core = true
    /// Hints for the checks: "stroke", "gradient", "pattern", "filters", "loose" (content does not fill its bounds),
    /// "locked", "noContent" (adjustment), "canvasFill" (fill layer), "fx", "blendfx" (effects with non-normal blend).
    var flags: Set<String> = []
    var make: () -> (DocumentState, [UUID])

    func has(_ f: String) -> Bool { flags.contains(f) }
}

enum QASubjects {
    static var W: Int { LQA.W }
    static var H: Int { LQA.H }

    // MARK: Building blocks

    /// Opaque, asymmetric test image (so flips / rotations are visible).
    static func image(_ w: Int, _ h: Int, seed: Int = 0) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        let cols: [RGBA] = [RGBA(hex: "E94F37")!, RGBA(hex: "3F88C5")!, RGBA(hex: "44BBA4")!, RGBA(hex: "F6AE2D")!]
        let W = CGFloat(w), H = CGFloat(h)
        let rects = [CGRect(x: 0, y: 0, width: W / 2, height: H / 2), CGRect(x: W / 2, y: 0, width: W / 2, height: H / 2),
                     CGRect(x: 0, y: H / 2, width: W / 2, height: H / 2), CGRect(x: W / 2, y: H / 2, width: W / 2, height: H / 2)]
        for (i, r) in rects.enumerated() { c.setFillColor(cols[(i + seed) % 4].cgColor); c.fill(r) }
        c.setStrokeColor(RGBA.white.cgColor); c.setLineWidth(max(3, W / 20))
        c.move(to: CGPoint(x: W * 0.1, y: H * 0.15)); c.addLine(to: CGPoint(x: W * 0.7, y: H * 0.85)); c.strokePath()
        c.setFillColor(RGBA.black.cgColor)
        c.fillEllipse(in: CGRect(x: W * 0.7, y: H * 0.1, width: W * 0.18, height: H * 0.25))
        b.markDirty()
        return b
    }

    static func base() -> DocumentState {
        var st = SelfTest.baseState(W, H)
        let under = PixelBuffer(width: W, height: H)
        under.context.setFillColor(RGBA(r: 0.1, g: 0.55, b: 0.5, a: 0.8).cgColor)
        under.context.fillEllipse(in: CGRect(x: 110, y: 90, width: 200, height: 140))
        under.markDirty()
        st.layers.append(Layer.raster(name: "Under", buffer: under))
        return st
    }

    static func one(_ l: Layer) -> (DocumentState, [UUID]) {
        var st = base()
        st.layers.append(l)
        return (st, [l.id])
    }

    static func ellipseMask(_ r: CGRect = CGRect(x: 90, y: 70, width: 150, height: 110), outside: UInt8 = 0) -> LayerMask {
        let b = PixelBuffer(width: W, height: H, gray: outside)
        b.context.setFillColor(gray: outside == 0 ? 1 : 0, alpha: 1)
        b.context.fillEllipse(in: r)
        b.markDirty()
        return LayerMask(buffer: b, origin: .zero, outsideValue: outside)
    }

    // MARK: Layer kinds

    static func rasterSmall(_ name: String = "Raster") -> Layer {
        Layer.raster(name: name, buffer: image(140, 90), origin: IPoint(x: 80, y: 70))
    }

    static func text(_ s: String = "Hagly Qj", size: Double = 42, at p: CGPoint = CGPoint(x: 70, y: 80), _ body: (inout TextContent) -> Void = { _ in }) -> Layer {
        var t = TextContent()
        t.text = s; t.fontSize = size; t.position = p; t.color = RGBA(hex: "20124D")!
        body(&t)
        return Layer(name: "Type", content: .text(t))
    }

    static func shape(_ g: ShapeGeometry, _ body: (inout ShapeContent) -> Void = { _ in }) -> Layer {
        var s = ShapeContent(geometry: g, fill: .color(RGBA(hex: "E94F37")!))
        body(&s)
        return Layer(name: "Shape", content: .shape(s))
    }

    static let shapeRect = CGRect(x: 80, y: 70, width: 150, height: 100)

    static func smartImage(_ body: (inout SmartObjectContent) -> Void = { _ in }) -> Layer {
        var so = SmartObjectContent(source: .image(image(160, 100, seed: 1)), quad: Quad(rect: CGRect(x: 80, y: 70, width: 160, height: 100)), sourceName: "img")
        body(&so)
        return Layer(name: "Smart", content: .smartObject(so))
    }

    static func innerDoc(_ w: Int = 160, _ h: Int = 100) -> DocumentState {
        var inner = DocumentState(width: w, height: h)
        inner.layers = [Layer.raster(name: "bg", buffer: image(w, h, seed: 2))]
        var t = TextContent()
        t.text = "SO"; t.fontSize = Double(h) * 0.5; t.position = CGPoint(x: Double(w) * 0.2, y: Double(h) * 0.2); t.color = .white
        inner.layers.append(Layer(name: "t", content: .text(t)))
        return inner
    }

    static func smartDoc(_ body: (inout SmartObjectContent) -> Void = { _ in }) -> Layer {
        var so = SmartObjectContent(source: .document(innerDoc()), quad: Quad(rect: CGRect(x: 80, y: 70, width: 160, height: 100)), sourceName: "doc")
        body(&so)
        return Layer(name: "Smart Doc", content: .smartObject(so))
    }

    static func fx(_ body: (inout LayerEffects) -> Void) -> LayerEffects {
        var e = LayerEffects()
        body(&e)
        return e
    }

    // MARK: Subject list

    static func all() -> [QASubject] {
        var s: [QASubject] = []
        func add(_ name: String, core: Bool = true, flags: Set<String> = [], _ make: @escaping () -> (DocumentState, [UUID])) {
            s.append(QASubject(name: name, core: core, flags: flags, make: make))
        }
        func addLayer(_ name: String, core: Bool = true, flags: Set<String> = [], _ make: @escaping () -> Layer) {
            add(name, core: core, flags: flags) { one(make()) }
        }

        // --- Raster
        addLayer("raster.small") { rasterSmall() }
        addLayer("raster.canvas") {
            let b = PixelBuffer(width: W, height: H)
            b.drawImage(image(180, 110).makeCGImage(), in: CGRect(x: 70, y: 60, width: 180, height: 110))
            b.markDirty()
            return Layer.raster(name: "Raster", buffer: b)
        }
        addLayer("raster.offcanvas") { Layer.raster(name: "Raster", buffer: image(200, 150), origin: IPoint(x: -60, y: -40)) }

        // --- Text
        addLayer("text.point", flags: ["loose"]) { text() }
        addLayer("text.paragraph", flags: ["loose"]) {
            text("Paragraph text wraps inside its box and keeps going.", size: 20) { $0.boxSize = CGSize(width: 190, height: 110) }
        }
        addLayer("text.area", flags: ["loose"]) {
            var base = TextContent()
            base.text = "Area type flows inside a closed shape such as this ellipse here."; base.fontSize = 15; base.color = RGBA(hex: "20124D")!
            let t = TextContent.areaText(in: VectorPath.ellipse(CGRect(x: 70, y: 60, width: 200, height: 150)), base: base)
            return Layer(name: "Type", content: .text(t))
        }
        addLayer("text.path", flags: ["loose"]) {
            var t = TextContent()
            t.text = "Type on a path"; t.fontSize = 26; t.color = RGBA(hex: "20124D")!
            let a = PathPoint(anchor: CGPoint(x: 60, y: 170), inControl: CGPoint(x: 60, y: 170), outControl: CGPoint(x: 120, y: 60))
            let b = PathPoint(anchor: CGPoint(x: 300, y: 130), inControl: CGPoint(x: 220, y: 60), outControl: CGPoint(x: 300, y: 130))
            t.pathText = TextOnPath(path: VectorPath(subpaths: [Subpath(points: [a, b], closed: false)]), startOffset: 8)
            return Layer(name: "Type", content: .text(t))
        }
        addLayer("text.vertical", flags: ["loose"]) { text("Tall", size: 34, at: CGPoint(x: 170, y: 60)) { $0.orientation = .vertical } }
        for (style, bend) in [(WarpStyle.arc, 45.0), (.flag, 60), (.fisheye, 50), (.twist, 40), (.rise, -50)] {
            addLayer("text.warp.\(style.rawValue)", flags: ["loose"]) { text("Warped") { $0.warp = TextWarp(style: style, bend: bend, horizontalDistortion: 10) } }
        }
        addLayer("text.runs", flags: ["loose", "runs"]) {
            text("Mixed runs", size: 36) { t in
                t.runs = [TextStyleRun(location: 0, length: 5, style: CharacterStyle(fontSize: 52, color: RGBA(hex: "C2185B")!)),
                          TextStyleRun(location: 6, length: 4, style: CharacterStyle(fauxItalic: true, underline: true))]
                t.tracking = 40
            }
        }
        addLayer("text.variable", flags: ["loose"]) {
            text("Variable", size: 40) { t in
                for f in ["SFPro-Regular", ".SFNS-Regular", "Skia-Regular", "HelveticaNeue"] where !FontAxis.axes(fontName: f).isEmpty {
                    t.fontName = f
                    if let ax = FontAxis.axes(fontName: f).first { t.variations = [ax.tag: ax.min + (ax.max - ax.min) * 0.8] }
                    break
                }
            }
        }
        addLayer("text.list", flags: ["loose"]) {
            text("First item\nSecond item\nThird", size: 20) { $0.list = TextListStyle(kind: .numbered); $0.boxSize = CGSize(width: 190, height: 110) }
        }
        addLayer("text.fit", flags: ["loose"]) {
            text("Fit me to the box", size: 12) { $0.boxSize = CGSize(width: 200, height: 90); $0.fitToBox = TextFit() }
        }
        addLayer("text.scaled", flags: ["loose"]) {
            text("Faux Styles", size: 30) { t in
                t.horizontalScale = 1.4; t.verticalScale = 0.8; t.fauxBold = true; t.fauxItalic = true; t.underline = true; t.strikethrough = true
                t.allCaps = true; t.alignment = .center; t.baselineShift = 4
            }
        }

        // --- Shapes
        addLayer("shape.rect") { shape(.rectangle(shapeRect, cornerRadius: 0)) }
        addLayer("shape.rounded") { shape(.rectangle(shapeRect, cornerRadius: 22)) }
        addLayer("shape.ellipse") { shape(.ellipse(shapeRect)) }
        addLayer("shape.polygon") { shape(.polygon(CGRect(x: 90, y: 60, width: 130, height: 130), sides: 6, starRatio: 1)) }
        addLayer("shape.star") { shape(.polygon(CGRect(x: 90, y: 60, width: 130, height: 130), sides: 5, starRatio: 0.45)) }
        addLayer("shape.triangle") { shape(.polygon(CGRect(x: 90, y: 60, width: 130, height: 120), sides: 3, starRatio: 1)) }
        addLayer("shape.line") { shape(.line(CGPoint(x: 80, y: 80), CGPoint(x: 250, y: 170), weight: 9)) }
        addLayer("shape.library") { shape(.library("heart", CGRect(x: 90, y: 60, width: 140, height: 120))) }
        addLayer("shape.path.boolean", flags: ["loose"]) {   // the box encloses every component, subtracted ones included (as in Photoshop)
            let a = VectorPath.rect(CGRect(x: 80, y: 70, width: 150, height: 100))
            let b = VectorPath.ellipse(CGRect(x: 150, y: 100, width: 110, height: 90)).withOperation(.subtract)
            let c = VectorPath.ellipse(CGRect(x: 60, y: 50, width: 60, height: 60)).withOperation(.combine)
            return shape(.path(VectorPath(subpaths: a.subpaths + b.subpaths + c.subpaths)))
        }
        for al in StrokeAlignment.allCases {
            addLayer("shape.stroke.\(al.rawValue)", flags: ["stroke"]) {
                shape(.rectangle(shapeRect, cornerRadius: 12)) { $0.stroke = StrokeStyle(paint: .color(RGBA(hex: "20124D")!), width: 8, alignment: al) }
            }
        }
        addLayer("shape.stroke.dashed", flags: ["stroke"]) {
            shape(.ellipse(shapeRect)) { $0.stroke = StrokeStyle(paint: .color(.black), width: 5, alignment: .center, cap: .round, join: .round, dash: [2, 2]) }
        }
        addLayer("shape.stroke.only", flags: ["stroke", "loose"]) {
            shape(.rectangle(shapeRect, cornerRadius: 0)) { $0.fill = .none; $0.stroke = StrokeStyle(paint: .color(.black), width: 6, alignment: .center) }
        }
        addLayer("shape.star.stroke", flags: ["stroke"]) {
            shape(.polygon(CGRect(x: 90, y: 60, width: 130, height: 130), sides: 5, starRatio: 0.4)) {
                $0.stroke = StrokeStyle(paint: .color(.black), width: 6, alignment: .center)
            }
        }
        addLayer("shape.gradient", flags: ["gradient"]) {
            shape(.rectangle(shapeRect, cornerRadius: 10)) { $0.fill = .gradient(GradientFill(gradient: ColorGradient.presets[3], angle: 30)) }
        }
        addLayer("shape.pattern", flags: ["pattern"]) { shape(.ellipse(shapeRect)) { $0.fill = .pattern(id: "bricks", scale: 0.5) } }

        // --- Smart objects
        addLayer("smart.image") { smartImage() }
        addLayer("smart.document") { smartDoc() }
        addLayer("smart.filters", flags: ["filters"]) { smartImage { $0.filters = [FilterInstance(kind: .gaussianBlur), FilterInstance(kind: .emboss)] } }
        addLayer("smart.warp", flags: ["warp"]) {
            smartImage { so in
                let b = so.quad.bounds
                so.warp = MeshWarpData(from: MeshGrid.regular(b, cols: 40, rows: 40), to: WarpStyle.arc.mesh(b, bend: 0.5, h: 0, v: 0))
            }
        }
        addLayer("smart.stack") {
            var inner = DocumentState(width: 160, height: 100)
            inner.layers = (0..<3).map { Layer.raster(name: "s\($0)", buffer: image(160, 100, seed: $0)) }
            var so = SmartObjectContent(source: .document(inner), quad: Quad(rect: CGRect(x: 80, y: 70, width: 160, height: 100)), sourceName: "stack")
            so.stackMode = StackMode.mean.rawValue
            return Layer(name: "Stack", content: .smartObject(so))
        }
        addLayer("smart.perspective") {
            smartImage { $0.quad = Quad(tl: CGPoint(x: 90, y: 80), tr: CGPoint(x: 250, y: 60), br: CGPoint(x: 240, y: 190), bl: CGPoint(x: 70, y: 160)) }
        }
        addLayer("smart.rotated") {
            smartDoc { so in
                let c = so.quad.center
                so.quad = so.quad.mapped { $0.rotated(by: 0.35, around: c) }
            }
        }
        addLayer("smart.downscaled") {
            var so = SmartObjectContent(source: .image(image(640, 400, seed: 3)), quad: Quad(rect: CGRect(x: 90, y: 80, width: 160, height: 100)), sourceName: "big")
            so.sourceRevision = 1
            return Layer(name: "Smart", content: .smartObject(so))
        }
        add("smart.linked") {
            let url = LQA.out.appendingPathComponent("qa_linked_source.imagecrat")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? DocumentIO.saveNative(Document(state: innerDoc(), name: "linked"), to: url)
            }
            var l = smartDoc()
            if var so = l.smart { so.linkedURL = url; so.linkedModified = AppActions.modificationDate(url); so.sourceName = url.lastPathComponent; l.smart = so }
            return one(l)
        }

        // --- Fill layers
        addLayer("fill.solid", flags: ["canvasFill"]) {
            var l = Layer(name: "Color Fill", content: .fill(FillContent(paint: .color(RGBA(hex: "F6AE2D")!))))
            l.mask = ellipseMask()
            return l
        }
        addLayer("fill.gradient", flags: ["canvasFill"]) {
            var l = Layer(name: "Gradient Fill", content: .fill(FillContent(paint: .gradient(GradientFill(gradient: ColorGradient.presets[4], angle: 45)))))
            l.mask = ellipseMask()
            return l
        }
        addLayer("fill.gradient.placed", flags: ["canvasFill"]) {
            var g = GradientFill(gradient: ColorGradient.presets[2], type: .radial)
            g.start = CGPoint(x: 150, y: 120); g.end = CGPoint(x: 240, y: 170)
            var l = Layer(name: "Gradient Fill", content: .fill(FillContent(paint: .gradient(g))))
            l.mask = ellipseMask()
            return l
        }
        addLayer("fill.pattern", flags: ["canvasFill"]) {
            var l = Layer(name: "Pattern Fill", content: .fill(FillContent(paint: .pattern(id: "hex", scale: 0.5))))
            l.mask = ellipseMask()
            return l
        }

        // --- Adjustment layers
        let adjKinds: [AdjustmentKind] = [.brightnessContrast, .levels, .curves, .exposure, .vibrance, .hueSaturation, .colorBalance, .blackWhite,
                                          .photoFilter, .channelMixer, .invert, .posterize, .threshold, .gradientMap, .selectiveColor, .colorLookup]
        for k in (LQA.full ? adjKinds : [.levels, .hueSaturation, .invert, .gradientMap]) {
            addLayer("adjustment.\(k.rawValue)", core: false, flags: ["noContent"]) {
                var a = AdjustmentSettings(kind: k)
                a.brightness = 60; a.contrast = 30; a.exposure = 1.2
                var l = Layer(name: k.displayName, content: .adjustment(a))
                l.mask = ellipseMask()
                return l
            }
        }

        // --- Groups, artboards, frames
        add("group.passthrough", flags: ["loose"]) {
            let g = Layer(name: "Group", content: .group(GroupContent(children: [shape(.rectangle(shapeRect, cornerRadius: 16)), text("In group", size: 30, at: CGPoint(x: 90, y: 150))])))
            return one(g)
        }
        add("group.normal", flags: ["loose"]) {
            var multiply = rasterSmall()
            multiply.blendMode = .multiply
            var g = Layer(name: "Group", content: .group(GroupContent(children: [shape(.ellipse(shapeRect)), multiply])))
            g.blendMode = .normal; g.opacity = 0.8
            g.mask = ellipseMask(CGRect(x: 60, y: 50, width: 170, height: 110))
            return one(g)
        }
        add("group.nested", flags: ["loose"]) {
            let inner = Layer(name: "Inner", content: .group(GroupContent(children: [smartImage(), text("Nested", size: 28, at: CGPoint(x: 100, y: 180))])))
            let g = Layer(name: "Outer", content: .group(GroupContent(children: [shape(.rectangle(CGRect(x: 60, y: 50, width: 120, height: 80), cornerRadius: 0)), inner])))
            return one(g)
        }
        add("group.collapsed.clipchild", flags: ["loose"]) {
            var clipped = Layer.raster(name: "Clipped", buffer: image(200, 140, seed: 1), origin: IPoint(x: 60, y: 50))
            clipped.isClipped = true
            let g = Layer(name: "Group", content: .group(GroupContent(children: [shape(.ellipse(shapeRect)), clipped], isExpanded: false)))
            return one(g)
        }
        add("artboard", flags: ["loose", "artboard"]) {
            var ab = Layer(name: "Artboard 1", content: .group(GroupContent(children: [shape(.ellipse(CGRect(x: 20, y: 40, width: 150, height: 110))), text("Board", size: 32, at: CGPoint(x: 150, y: 170))],
                                                                           isExpanded: true, artboard: Artboard(rect: CGRect(x: 60, y: 40, width: 260, height: 200)))))
            ab.blendMode = .normal
            return one(ab)
        }
        add("frame.image", flags: ["loose", "frame"]) {
            var st = base()
            var frame = Layer(name: "Frame 1", content: .group(GroupContent(children: [smartImage { $0.quad = Quad(rect: CGRect(x: 60, y: 50, width: 224, height: 140)) }])))
            frame.vectorMask = VectorPath.rect(CGRect(x: 90, y: 70, width: 150, height: 100))
            st.layers.append(frame)
            st.toolData.frames.append(FrameInfo(id: frame.id, ellipse: false))
            return (st, [frame.id])
        }

        // --- Video and generative layers
        add("video", flags: ["video"]) {
            var st = base()
            let url = LQA.out.appendingPathComponent("qa_clip.mp4")
            if !FileManager.default.fileExists(atPath: url.path) {
                var clip = DocumentState(width: 160, height: 100)
                clip.layers = [Layer.raster(name: "a", buffer: image(160, 100, seed: 0)), Layer.raster(name: "b", buffer: image(160, 100, seed: 2))]
                clip.frames = Animation.framesFromLayers(clip, delay: 0.2)
                try? AnimationExport.writeVideo(clip, to: url)
            }
            let d = Document(state: st, name: "video")
            if let id = try? VideoLayerImport.addVideoLayer(url, to: d) {
                st = d.state
                st.updateLayer(id) { l in
                    if var so = l.smart { so.quad = Quad(rect: CGRect(x: 80, y: 70, width: 160, height: 100)); l.smart = so }
                }
                return (st, [id])
            }
            // no decoder available: a plain smart object with a video track
            let l = smartImage()
            st.layers.append(l)
            return (st, [l.id])
        }
        add("generative") {
            var st = base()
            let l = Layer.raster(name: "Generative Fill", buffer: image(140, 90, seed: 3), origin: IPoint(x: 80, y: 70))
            st.layers.append(l)
            var info = GenerativeLayerInfo()
            info.prompt = "a test"; info.rect = IRect(x: 80, y: 70, width: 140, height: 90)
            info.variations = [image(140, 90, seed: 3), image(140, 90, seed: 1)]
            st.generative[l.id] = info
            return (st, [l.id])
        }

        // ===== Attribute subjects (core: false) =====
        func attr(_ name: String, flags: Set<String> = [], _ make: @escaping () -> Layer) { addLayer(name, core: false, flags: flags, make) }

        attr("mask.linked.raster") { var l = rasterSmall(); l.mask = ellipseMask(); return l }
        attr("mask.unlinked.text", flags: ["loose", "unlinkedMask"]) { var l = text(); l.mask = ellipseMask(CGRect(x: 60, y: 70, width: 160, height: 60)); l.mask?.isLinked = false; return l }
        attr("mask.feather.shape") { var l = shape(.rectangle(shapeRect, cornerRadius: 0)); l.mask = ellipseMask(); l.mask?.feather = 8; l.mask?.density = 0.7; return l }
        attr("mask.linked.smart") { var l = smartImage(); l.mask = ellipseMask(); return l }
        attr("mask.inverted.shape") { var l = shape(.ellipse(shapeRect)); l.mask = ellipseMask(CGRect(x: 120, y: 90, width: 70, height: 60), outside: 255); return l }
        attr("mask.disabled.raster") { var l = rasterSmall(); l.mask = ellipseMask(); l.mask?.isEnabled = false; return l }
        attr("vmask.raster") { var l = rasterSmall(); l.vectorMask = VectorPath.ellipse(CGRect(x: 95, y: 75, width: 110, height: 75)); return l }
        attr("vmask.text", flags: ["loose"]) { var l = text(); l.vectorMask = VectorPath.rect(CGRect(x: 80, y: 84, width: 120, height: 30), radius: 8); return l }
        attr("mask+vmask.smart") { var l = smartDoc(); l.mask = ellipseMask(); l.vectorMask = VectorPath.rect(CGRect(x: 100, y: 60, width: 100, height: 140)); l.layerMaskHidesEffects = true; return l }

        add("clip.base", core: false) {
            var st = base()
            let b = shape(.ellipse(shapeRect))
            var c1 = Layer.raster(name: "Clipped", buffer: image(200, 140, seed: 1), origin: IPoint(x: 60, y: 50)); c1.isClipped = true
            var c2 = Layer(name: "Invert", content: .adjustment(AdjustmentSettings(kind: .invert))); c2.isClipped = true
            c2.mask = ellipseMask(CGRect(x: 150, y: 60, width: 120, height: 140))
            st.layers += [b, c1, c2]
            return (st, [b.id])
        }
        add("clip.clipped.raster", core: false) {
            var st = base()
            let b = shape(.ellipse(shapeRect))
            var c1 = Layer.raster(name: "Clipped", buffer: image(200, 140, seed: 1), origin: IPoint(x: 60, y: 50)); c1.isClipped = true
            st.layers += [b, c1]
            return (st, [c1.id])
        }
        add("clip.clipped.text", core: false, flags: ["loose"]) {
            var st = base()
            let b = Layer.raster(name: "Base", buffer: image(180, 60), origin: IPoint(x: 70, y: 80))
            var c1 = text("Clipped Qy", size: 46, at: CGPoint(x: 60, y: 70)); c1.isClipped = true
            st.layers += [b, c1]
            return (st, [c1.id])
        }

        // Layer effects, one at a time, on alternating layer kinds
        let fxCases: [(String, Bool, (inout LayerEffects) -> Void)] = [
            ("dropShadow", true, { $0.dropShadow.enabled = true; $0.dropShadow.distance = 9; $0.dropShadow.size = 8 }),
            ("innerShadow", true, { $0.innerShadow.enabled = true; $0.innerShadow.distance = 6; $0.innerShadow.size = 6 }),
            ("outerGlow", true, { $0.outerGlow.enabled = true; $0.outerGlow.size = 14; $0.outerGlow.color = RGBA(hex: "FFEE00")! }),
            ("innerGlow", true, { $0.innerGlow.enabled = true; $0.innerGlow.size = 10; $0.innerGlow.color = .white }),
            ("bevel", true, { $0.bevel.enabled = true; $0.bevel.size = 8 }),
            ("satin", true, { $0.satin.enabled = true }),
            ("colorOverlay", false, { $0.colorOverlay.enabled = true; $0.colorOverlay.color = RGBA(hex: "2E86DE")! }),
            ("gradientOverlay", false, { $0.gradientOverlay.enabled = true; $0.gradientOverlay.fill.gradient = ColorGradient.presets[3] }),
            ("patternOverlay", false, { $0.patternOverlay.enabled = true; $0.patternOverlay.patternID = "dots" }),
            ("stroke", false, { $0.stroke.enabled = true; $0.stroke.size = 5; $0.stroke.paint = .color(.white) }),
            ("strokeInside", false, { $0.stroke.enabled = true; $0.stroke.size = 6; $0.stroke.position = .inside; $0.stroke.paint = .color(.black) }),
            ("multi", true, { e in
                e.dropShadow.enabled = true
                var s2 = ShadowEffect(); s2.enabled = true; s2.distance = 18; s2.size = 4; s2.color = RGBA(hex: "C2185B")!; s2.angle = 30; s2.useGlobalLight = false
                e.extraDropShadows = [s2]
                e.stroke.enabled = true; e.stroke.size = 3; e.stroke.paint = .color(.white)
                var k2 = StrokeEffect(); k2.enabled = true; k2.size = 7; k2.paint = .color(.black)
                e.extraStrokes = [k2]
            }),
        ]
        for (i, c) in fxCases.enumerated() {
            let kindIndex = i % 4
            let flags = Set<String>(c.1 ? ["fx", "blendfx"] : ["fx"]).union(kindIndex == 1 ? ["loose"] : [])
            attr("fx.\(c.0).\(["shape", "text", "raster", "smart"][kindIndex])", flags: flags) {
                var l: Layer
                switch kindIndex {
                case 0: l = shape(.rectangle(shapeRect, cornerRadius: 18))
                case 1: l = text("Effects", size: 50)
                case 2: l = rasterSmall()
                default: l = smartImage()
                }
                l.effects = fx(c.2)
                return l
            }
        }
        attr("mask.fx.stroke.shape", flags: ["fx"]) {
            var l = shape(.rectangle(shapeRect, cornerRadius: 0)); l.mask = ellipseMask(CGRect(x: 60, y: 90, width: 150, height: 110))
            l.effects = fx { $0.stroke.enabled = true; $0.stroke.size = 5; $0.stroke.paint = .color(.black) }
            return l
        }
        attr("vmask.fx.stroke.raster", flags: ["fx"]) {
            var l = rasterSmall(); l.vectorMask = VectorPath.ellipse(CGRect(x: 95, y: 75, width: 110, height: 75))
            l.effects = fx { $0.stroke.enabled = true; $0.stroke.size = 4; $0.stroke.paint = .color(.white); $0.colorOverlay.enabled = true; $0.colorOverlay.opacity = 0.4 }
            return l
        }
        add("fx.globalLight.text", core: false, flags: ["fx", "loose"]) {
            var l = text("Light", size: 56)
            l.effects = fx { $0.dropShadow.enabled = true; $0.dropShadow.distance = 12; $0.dropShadow.size = 3; $0.dropShadow.blendMode = .normal }
            var (st, ids) = one(l)
            st.globalLight = GlobalLight(angle: -40, altitude: 60)
            ids = [l.id]
            return (st, ids)
        }

        // Advanced blending, opacity, modes
        attr("blendif.raster") { var l = rasterSmall(); l.blendIf.thisLow = [60, 110]; l.blendIf.underHigh = [170, 215]; return l }
        attr("channels.raster") { var l = rasterSmall(); l.channelR = false; return l }
        attr("fillopacity.text", flags: ["fx", "loose"]) { var l = text("Fill 30", size: 52); l.fillOpacity = 0.3; l.effects = fx { $0.stroke.enabled = true; $0.stroke.size = 3; $0.stroke.paint = .color(.black) }; return l }
        attr("fillopacity.shape") { var l = shape(.ellipse(shapeRect)); l.fillOpacity = 0.4; return l }
        attr("opacity.smart") { var l = smartImage(); l.opacity = 0.5; return l }
        attr("blend.multiply.shape", flags: ["blendmode"]) { var l = shape(.rectangle(shapeRect, cornerRadius: 10)); l.blendMode = .multiply; return l }
        attr("blend.screen.raster", flags: ["blendmode"]) { var l = rasterSmall(); l.blendMode = .screen; return l }
        attr("blend.difference.text", flags: ["blendmode", "loose"]) { var l = text("Differ", size: 60); l.blendMode = .difference; l.text?.color = .white; return l }
        attr("blend.overlay.smart", flags: ["blendmode"]) { var l = smartImage(); l.blendMode = .overlay; l.opacity = 0.8; return l }
        add("knockout.shallow.shape", core: false, flags: ["knockout", "loose"]) {
            var k = shape(.ellipse(CGRect(x: 110, y: 90, width: 90, height: 70))); k.knockout = .shallow; k.fillOpacity = 0
            let g = Layer(name: "Group", content: .group(GroupContent(children: [rasterSmall(), k])))
            var st = base(); st.layers.append(g)
            return (st, [k.id])
        }
        add("knockout.deep.text", core: false, flags: ["knockout", "loose"]) {
            var k = text("KO", size: 70, at: CGPoint(x: 100, y: 80)); k.knockout = .deep; k.fillOpacity = 0
            var st = base(); st.layers += [rasterSmall(), k]
            return (st, [k.id])
        }

        // Locks, links, labels, visibility
        attr("lock.transparency.raster") { var l = rasterSmall(); l.locks.transparency = true; return l }
        attr("lock.pixels.raster") { var l = rasterSmall(); l.locks.pixels = true; return l }
        attr("lock.position.shape", flags: ["locked"]) { var l = shape(.ellipse(shapeRect)); l.locks.position = true; return l }
        attr("lock.all.text", flags: ["locked", "loose"]) { var l = text(); l.locks.all = true; return l }
        attr("label.shape") { var l = shape(.ellipse(shapeRect)); l.colorLabel = .red; return l }
        attr("hidden.text", flags: ["hidden", "loose"]) { var l = text(); l.isVisible = false; return l }
        add("linked.pair", core: false, flags: ["loose", "linked"]) {
            var st = base()
            let link = UUID()
            var a = shape(.rectangle(CGRect(x: 60, y: 60, width: 90, height: 70), cornerRadius: 8)); a.linkID = link
            var b = text("Linked", size: 30, at: CGPoint(x: 160, y: 150)); b.linkID = link
            st.layers += [a, b]
            return (st, [a.id])
        }
        return s
    }
}
