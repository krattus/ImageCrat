import Foundation
import CoreGraphics
import ImageIO
import ImageCratCore

// Documents that cover every layer kind and attribute the PSD exporter writes (self tests and the files for
// checking in Photoshop).

enum PSDExportSamples {
    static func background(_ w: Int, _ h: Int) -> Layer {
        let bg = PixelBuffer(width: w, height: h)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "F6D365")!.cgColor, RGBA(hex: "FDA085")!.cgColor, RGBA(hex: "5B86E5")!.cgColor] as CFArray,
                           locations: [0, 0.5, 1])!
        bg.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        // a few saturated patches so colour adjustments have something to act on
        let cols = ["E63946", "2A9D8F", "F4A261", "264653", "8338EC", "06D6A0"]
        for (i, c) in cols.enumerated() {
            bg.context.setFillColor(RGBA(hex: c)!.cgColor)
            bg.context.fill(CGRect(x: 12 + i * (w - 24) / cols.count, y: h - 70, width: (w - 24) / cols.count - 6, height: 56))
        }
        bg.context.setFillColor(gray: 1, alpha: 1)
        bg.context.fillEllipse(in: CGRect(x: w / 2 - 50, y: 20, width: 100, height: 100))
        bg.markDirty()
        return Layer.raster(name: "Background", buffer: bg)
    }

    static func base(_ w: Int = 480, _ h: Int = 320) -> DocumentState {
        var st = DocumentState(width: w, height: h)
        st.layers = [background(w, h)]
        return st
    }

    static func shape(_ name: String, _ g: ShapeGeometry, fill: PaintStyle, stroke: StrokeStyle = StrokeStyle(), transform: CGAffineTransform = .identity) -> Layer {
        var s = ShapeContent(geometry: g, fill: fill)
        s.stroke = stroke
        s.transform = transform
        return Layer(name: name, content: .shape(s))
    }

    static func text(_ name: String, _ s: String, font: String = "Helvetica", size: Double = 36, at p: CGPoint, color: RGBA = .black, _ edit: (inout TextContent) -> Void = { _ in }) -> Layer {
        var t = TextContent()
        t.text = s; t.fontName = font; t.fontSize = size; t.color = color; t.position = p
        edit(&t)
        return Layer(name: name, content: .text(t))
    }

    static func adjustment(_ name: String, _ kind: AdjustmentKind, _ edit: (inout AdjustmentSettings) -> Void) -> Layer {
        var a = AdjustmentSettings(kind: kind)
        edit(&a)
        return Layer(name: name, content: .adjustment(a))
    }

    static func ellipseMask(_ w: Int, _ h: Int, _ r: CGRect, outside: UInt8 = 0) -> LayerMask {
        let b = PixelBuffer(width: w, height: h, gray: outside)
        b.context.setFillColor(gray: outside == 0 ? 1 : 0, alpha: 1)
        b.context.fillEllipse(in: r)
        b.markDirty()
        return LayerMask(buffer: b, origin: .zero, outsideValue: outside)
    }

    /// One document per adjustment kind (name, settings), each on the shared background.
    static func adjustmentCases() -> [(String, AdjustmentSettings)] {
        var out: [(String, AdjustmentSettings)] = []
        func add(_ n: String, _ k: AdjustmentKind, _ e: (inout AdjustmentSettings) -> Void) { var a = AdjustmentSettings(kind: k); e(&a); out.append((n, a)) }
        add("brightness", .brightnessContrast) { $0.brightness = 40; $0.contrast = 25 }
        add("levels", .levels) { $0.levels[0] = LevelsChannel(inBlack: 20, inWhite: 230, gamma: 1.4, outBlack: 10, outWhite: 245); $0.levels[2].gamma = 0.8; $0.levels[3].inWhite = 200 }
        add("curves", .curves) { $0.curves[0].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.18), CGPoint(x: 0.75, y: 0.86), CGPoint(x: 1, y: 1)]
            $0.curves[1].points = [CGPoint(x: 0, y: 0.05), CGPoint(x: 0.5, y: 0.6), CGPoint(x: 1, y: 1)] }
        add("exposure", .exposure) { $0.exposure = 0.75; $0.offset = -0.02; $0.gamma = 1.1 }
        add("vibrance", .vibrance) { $0.vibrance = 60; $0.saturation = -15 }
        add("huesat", .hueSaturation) { $0.hue = 30; $0.hsSaturation = 20; $0.lightness = -5; $0.hsRanges[0].hue = -40; $0.hsRanges[4].saturation = 50 }
        add("colorize", .hueSaturation) { $0.colorize = true; $0.hue = 150; $0.hsSaturation = 0; $0.lightness = 10 }
        add("colorbalance", .colorBalance) { $0.midtones = ToneTriple(cyanRed: 30, magentaGreen: -20, yellowBlue: 15); $0.highlights.yellowBlue = -25; $0.preserveLuminosity = false }
        add("blackwhite", .blackWhite) { $0.bwReds = 70; $0.bwBlues = -10; $0.bwTint = true; $0.bwTintColor = RGBA(hex: "C9A66B")! }
        add("photofilter", .photoFilter) { $0.filterColor = RGBA(hex: "00B4D8")!; $0.density = 45; $0.preserveLuminosity = true }
        add("mixer", .channelMixer) { $0.mixRed = [80, 30, -10, 0]; $0.mixBlue = [0, 20, 90, 5] }
        add("mixermono", .channelMixer) { $0.monochrome = true; $0.mixRed = [40, 40, 20, 0] }
        add("invert", .invert) { _ in }
        add("posterize", .posterize) { $0.posterizeLevels = 5 }
        add("threshold", .threshold) { $0.thresholdLevel = 140 }
        add("gradientmap", .gradientMap) { $0.gradient = ColorGradient.presets[3]; $0.gradientReverse = false }
        add("selective", .selectiveColor) { $0.selective[0] = SelectiveColorEntry(cyan: -30, magenta: 10, yellow: 20, black: 0); $0.selective[7].black = 15; $0.selectiveAbsolute = true }
        add("desaturate", .desaturate) { _ in }
        add("shadowshighlights", .shadowsHighlights) { $0.shAmountShadows = 50 }
        add("colorlookup", .colorLookup) { $0.lookName = "Teal & Orange" }
        add("clarity", .clarity) { $0.params["amount"] = 40 }
        return out
    }

    static func adjustments() -> DocumentState {
        var st = base()
        let w = st.width, h = st.height
        var curves = adjustment("Curves", .curves) { $0.curves[0].points = [.zero, CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.85), CGPoint(x: 1, y: 1)] }
        curves.mask = ellipseMask(w, h, CGRect(x: 40, y: 30, width: 260, height: 200))
        var hs = adjustment("Hue/Saturation", .hueSaturation) { $0.hue = -25; $0.hsSaturation = 30 }
        hs.opacity = 0.7
        var bw = adjustment("Black & White (clipped)", .blackWhite) { $0.bwTint = true }
        bw.isClipped = true
        let disc = Layer(name: "Disc", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 300, y: 150, width: 150, height: 150)), fill: .color(RGBA(hex: "F72585")!))))
        var sh = adjustment("Shadows/Highlights (baked)", .shadowsHighlights) { $0.shAmountShadows = 60 }
        sh.mask = ellipseMask(w, h, CGRect(x: 0, y: 0, width: 240, height: 320))
        st.layers += [
            adjustment("Levels", .levels) { $0.levels[0] = LevelsChannel(inBlack: 15, inWhite: 240, gamma: 1.2, outBlack: 0, outWhite: 255) },
            curves, hs, disc, bw,
            adjustment("Photo Filter", .photoFilter) { $0.filterColor = RGBA(hex: "EC8A00")!; $0.density = 20 },
            sh,
        ]
        return st
    }

    static func fills() -> DocumentState {
        var st = base()
        var solid = Layer(name: "Solid Color", content: .fill(FillContent(paint: .color(RGBA(hex: "2B2D42")!))))
        solid.mask = ellipseMask(st.width, st.height, CGRect(x: 20, y: 20, width: 140, height: 140))
        var grad = Layer(name: "Gradient Fill", content: .fill(FillContent(paint: .gradient(GradientFill(gradient: ColorGradient.presets[6], type: .linear, angle: 30)))))
        grad.mask = ellipseMask(st.width, st.height, CGRect(x: 170, y: 20, width: 140, height: 140))
        var radial = Layer(name: "Radial Gradient", content: .fill(FillContent(paint: .gradient(GradientFill(gradient: ColorGradient.presets[1], type: .radial, angle: 90, scale: 0.6)))))
        radial.mask = ellipseMask(st.width, st.height, CGRect(x: 320, y: 20, width: 140, height: 140))
        var pat = Layer(name: "Pattern Fill", content: .fill(FillContent(paint: .pattern(id: "bricks", scale: 0.5))))
        pat.mask = ellipseMask(st.width, st.height, CGRect(x: 100, y: 170, width: 140, height: 140))
        var placed = GradientFill(gradient: ColorGradient.presets[4], type: .linear)
        placed.start = CGPoint(x: 260, y: 300); placed.end = CGPoint(x: 460, y: 180)
        var g2 = Layer(name: "Placed Gradient", content: .fill(FillContent(paint: .gradient(placed))))
        g2.mask = ellipseMask(st.width, st.height, CGRect(x: 260, y: 170, width: 140, height: 140))
        st.layers += [solid, grad, radial, pat, g2]
        return st
    }

    static func shapes() -> DocumentState {
        var st = base(560, 360)
        var dashed = StrokeStyle(paint: .color(RGBA(hex: "1D3557")!), width: 6, alignment: .inside, cap: .round, join: .round)
        dashed.dash = [2, 1.5]
        var rotated = shape("Rotated Rectangle", .rectangle(CGRect(x: -60, y: -30, width: 120, height: 60), cornerRadius: 0), fill: .color(RGBA(hex: "06D6A0")!),
                            transform: CGAffineTransform(rotationAngle: 0.4).concatenating(CGAffineTransform(translationX: 470, y: 90)))
        rotated.opacity = 0.85
        var star = shape("Star", .polygon(CGRect(x: 380, y: 200, width: 140, height: 140), sides: 5, starRatio: 0.5), fill: .gradient(GradientFill(gradient: ColorGradient.presets[3], type: .linear, angle: 90)))
        star.effects.dropShadow.enabled = true
        let curve = VectorPath(subpaths: [Subpath(points: [
            PathPoint(anchor: CGPoint(x: 30, y: 330), inControl: CGPoint(x: 30, y: 330), outControl: CGPoint(x: 80, y: 220)),
            PathPoint(anchor: CGPoint(x: 180, y: 300), inControl: CGPoint(x: 130, y: 360), outControl: CGPoint(x: 230, y: 240), isSmooth: true),
            PathPoint(anchor: CGPoint(x: 260, y: 330), inControl: CGPoint(x: 250, y: 280), outControl: CGPoint(x: 260, y: 330), isSmooth: false),
        ], closed: true)])
        var masked = shape("Ellipse with vector mask", .ellipse(CGRect(x: 280, y: 200, width: 100, height: 140)), fill: .color(RGBA(hex: "FFB703")!))
        masked.vectorMask = VectorPath.rect(CGRect(x: 280, y: 200, width: 100, height: 70))
        st.layers += [
            shape("Rectangle", .rectangle(CGRect(x: 20, y: 20, width: 150, height: 100), cornerRadius: 0), fill: .color(RGBA(hex: "E63946")!)),
            shape("Rounded Rectangle", .rectangle(CGRect(x: 190, y: 20, width: 150, height: 100), cornerRadius: 22), fill: .color(RGBA(hex: "457B9D")!),
                  stroke: StrokeStyle(paint: .color(RGBA(hex: "F1FAEE")!), width: 5, alignment: .outside)),
            shape("Ellipse", .ellipse(CGRect(x: 20, y: 140, width: 160, height: 110)), fill: .none, stroke: dashed),
            shape("Pattern Ellipse", .ellipse(CGRect(x: 200, y: 140, width: 160, height: 50)), fill: .pattern(id: "dots", scale: 1),
                  stroke: StrokeStyle(paint: .color(.black), width: 2, alignment: .center)),
            rotated, star,
            shape("Bezier Path", .path(curve), fill: .color(RGBA(hex: "8338EC")!)),
            shape("Line", .line(CGPoint(x: 300, y: 330), CGPoint(x: 540, y: 340), weight: 4), fill: .color(.black)),
            masked,
        ]
        return st
    }

    static func type() -> DocumentState {
        var st = base(640, 420)
        var mixed = TextContent()
        mixed.text = "Mixed Styles\nin one layer"
        mixed.fontName = "Helvetica"; mixed.fontSize = 40; mixed.color = RGBA(hex: "1B1F3A")!
        mixed.position = CGPoint(x: 20, y: 20)
        mixed.applyStyle(CharacterStyle(fontName: "Helvetica-Bold", fontSize: 56, color: RGBA(hex: "E94F37")!), to: NSRange(location: 0, length: 5))
        mixed.applyStyle(CharacterStyle(fontName: "Georgia-Italic", color: RGBA(hex: "2E86DE")!, underline: true), to: NSRange(location: 6, length: 6))
        mixed.applyStyle(CharacterStyle(tracking: 200, strikethrough: true), to: NSRange(location: 16, length: 3))
        mixed.applyStyle(CharacterStyle(baselineShift: 10, fauxBold: true), to: NSRange(location: 20, length: 5))
        st.layers += [
            Layer(name: "Mixed runs", content: .text(mixed)),
            text("Centred", "Centred point text\nsecond line", font: "Georgia", size: 26, at: CGPoint(x: 330, y: 30), color: RGBA(hex: "2D6A4F")!) { $0.alignment = .center; $0.leading = 40 },
            text("Right", "Right aligned", font: "Helvetica Neue", size: 24, at: CGPoint(x: 420, y: 130)) { $0.alignment = .right; $0.tracking = 80 },
            text("Paragraph", "Paragraph text flows inside its box and is justified, with hyphenation and indents.", font: "Times New Roman", size: 18,
                 at: CGPoint(x: 20, y: 170)) { $0.boxSize = CGSize(width: 260, height: 120); $0.alignment = .justify; $0.firstLineIndent = 12; $0.spaceAfter = 6; $0.hyphenate = true },
            text("Rotated", "Rotated & scaled", font: "Futura", size: 28, at: .zero, color: RGBA(hex: "7209B7")!) {
                $0.transform = CGAffineTransform(rotationAngle: -0.3).concatenating(CGAffineTransform(translationX: 320, y: 260)); $0.horizontalScale = 1.2 },
            text("Warped", "WARPED ARC", font: "Helvetica-Bold", size: 34, at: CGPoint(x: 330, y: 330), color: RGBA(hex: "D00000")!) {
                $0.warp = TextWarp(style: .arc, bend: 40, horizontalDistortion: 0, verticalDistortion: 0) },
            text("Vertical", "縦書き", font: "Hiragino Sans", size: 30, at: CGPoint(x: 610, y: 150)) { $0.orientation = .vertical },
            text("Caps", "All caps and small caps", font: "Helvetica", size: 20, at: CGPoint(x: 20, y: 320)) { $0.allCaps = true },
            text("Missing font", "Font that is not installed", font: "NoSuchFont-Regular", size: 20, at: CGPoint(x: 20, y: 370)),
        ]
        var fx = text("Text with style", "Layer style", font: "Helvetica-Bold", size: 32, at: CGPoint(x: 330, y: 190), color: .white)
        fx.effects.stroke.enabled = true; fx.effects.stroke.size = 3; fx.effects.stroke.paint = .color(RGBA(hex: "023E8A")!)
        fx.effects.dropShadow.enabled = true
        st.layers.append(fx)
        return st
    }

    static func checker(_ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        for y in stride(from: 0, to: h, by: 20) { for x in stride(from: 0, to: w, by: 20) {
            b.context.setFillColor(((x + y) / 20) % 2 == 0 ? RGBA(hex: "264653")!.cgColor : RGBA(hex: "E9C46A")!.cgColor)
            b.context.fill(CGRect(x: x, y: y, width: 20, height: 20))
        } }
        b.context.setFillColor(RGBA(hex: "E76F51")!.cgColor)
        b.context.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        b.markDirty()
        return b
    }

    static func smart(linkedFile: URL? = nil) -> DocumentState {
        var st = base(560, 380)
        let img = checker(160, 120)
        let plain = Layer(name: "Embedded image", content: .smartObject(SmartObjectContent(source: .image(img), quad: Quad(rect: CGRect(x: 20, y: 20, width: 160, height: 120)), sourceName: "checker.png")))
        let rq = Quad(rect: CGRect(x: -80, y: -60, width: 160, height: 120)).applying(CGAffineTransform(rotationAngle: 0.35).scaledBy(x: 0.8, y: 0.8).concatenating(CGAffineTransform(translationX: 300, y: 90)))
        let rot = Layer(name: "Rotated + scaled", content: .smartObject(SmartObjectContent(source: .image(img), quad: rq, sourceName: "checker.png")))
        let pq = Quad(tl: CGPoint(x: 400, y: 30), tr: CGPoint(x: 540, y: 50), br: CGPoint(x: 530, y: 170), bl: CGPoint(x: 390, y: 140))
        let persp = Layer(name: "Perspective", content: .smartObject(SmartObjectContent(source: .image(img), quad: pq, sourceName: "checker.png")))
        // a smart object holding a layered document (its own type and shape layers stay live inside the PSB)
        var inner = DocumentState(width: 200, height: 120)
        inner.layers = [shape("Inner shape", .rectangle(CGRect(x: 10, y: 10, width: 180, height: 100), cornerRadius: 16), fill: .color(RGBA(hex: "3A0CA3")!)),
                        text("Inner text", "Nested", font: "Helvetica-Bold", size: 34, at: CGPoint(x: 40, y: 40), color: .white)]
        let doc = Layer(name: "Layered contents", content: .smartObject(SmartObjectContent(source: .document(inner), quad: Quad(rect: CGRect(x: 20, y: 180, width: 200, height: 120)), sourceName: "Nested.psb")))
        var blurred = SmartObjectContent(source: .image(img), quad: Quad(rect: CGRect(x: 240, y: 200, width: 120, height: 90)), sourceName: "checker.png")
        var f = FilterInstance(kind: .gaussianBlur); f.values["radius"] = 4
        blurred.filters = [f]
        var warped = SmartObjectContent(source: .image(img), quad: Quad(rect: CGRect(x: 390, y: 200, width: 150, height: 110)), sourceName: "checker.png")
        let from = MeshGrid.regular(CGRect(x: 390, y: 200, width: 150, height: 110), cols: 3, rows: 3)
        var to = from
        to.positions[4] = CGPoint(x: to.positions[4].x + 18, y: to.positions[4].y - 14)
        warped.warp = MeshWarpData(from: from, to: to)
        st.layers += [plain, rot, persp, doc, Layer(name: "Smart filter (baked)", content: .smartObject(blurred)), Layer(name: "Mesh warp (baked)", content: .smartObject(warped))]
        if let url = linkedFile, let data = try? Data(contentsOf: url), let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            var so = SmartObjectContent(source: .image(PixelBuffer(cgImage: cg)), quad: Quad(rect: CGRect(x: 240, y: 310, width: 100, height: 60)), sourceName: url.lastPathComponent)
            so.linkedURL = url
            st.layers.append(Layer(name: "Linked file", content: .smartObject(so)))
        }
        return st
    }

    /// Masks, blending options, groups, clipping, labels, locks and document resources.
    static func attributes() -> DocumentState {
        var st = base(520, 360)
        let w = st.width, h = st.height
        func pixel(_ name: String, _ r: CGRect, _ c: String) -> Layer {
            let b = PixelBuffer(width: Int(r.width), height: Int(r.height))
            b.context.setFillColor(RGBA(hex: c)!.cgColor); b.context.fill(CGRect(origin: .zero, size: r.size)); b.markDirty()
            return Layer.raster(name: name, buffer: b, origin: IPoint(x: Int(r.minX), y: Int(r.minY)))
        }
        var masked = pixel("Mask density + feather", CGRect(x: 20, y: 20, width: 140, height: 100), "D62828")
        var m = ellipseMask(w, h, CGRect(x: 30, y: 25, width: 120, height: 90))
        m.density = 0.6; m.feather = 6
        masked.mask = m
        var disabled = pixel("Disabled unlinked mask", CGRect(x: 180, y: 20, width: 140, height: 100), "F77F00")
        var dm = ellipseMask(w, h, CGRect(x: 190, y: 30, width: 60, height: 60)); dm.isEnabled = false; dm.isLinked = false
        disabled.mask = dm
        var vmasked = pixel("Vector mask", CGRect(x: 340, y: 20, width: 160, height: 100), "003049")
        vmasked.vectorMask = VectorPath.ellipse(CGRect(x: 350, y: 25, width: 140, height: 90))
        var blendIf = pixel("Blend If", CGRect(x: 20, y: 140, width: 140, height: 90), "FCBF49")
        blendIf.blendIf = BlendIf(channel: .gray, thisLow: [0, 0], thisHigh: [255, 255], underLow: [40, 120], underHigh: [255, 255])
        var multiply = pixel("Multiply 70% fill 50%", CGRect(x: 180, y: 140, width: 140, height: 90), "6A4C93")
        multiply.blendMode = .multiply; multiply.opacity = 0.7; multiply.fillOpacity = 0.5
        multiply.effects.stroke.enabled = true; multiply.effects.stroke.size = 4
        multiply.colorLabel = .green
        var channels = pixel("Channels G only", CGRect(x: 340, y: 140, width: 160, height: 90), "FFFFFF")
        channels.channelR = false; channels.channelB = false
        channels.locks = LayerLocks(transparency: true, pixels: false, position: true, all: false)
        channels.colorLabel = .violet
        // clipping group inside a masked normal group, plus a knockout layer
        var base = shape("Clip base", .ellipse(CGRect(x: 40, y: 250, width: 160, height: 100)), fill: .color(.white))
        base.knockout = .none
        var clipped = pixel("Clipped stripes", CGRect(x: 20, y: 240, width: 220, height: 120), "118AB2")
        clipped.isClipped = true
        var clipAdj = adjustment("Clipped invert", .invert) { _ in }
        clipAdj.isClipped = true
        var group = Layer(name: "Masked group", content: .group(GroupContent(children: [base, clipped, clipAdj], isExpanded: true)))
        group.blendMode = .normal
        group.mask = ellipseMask(w, h, CGRect(x: 20, y: 240, width: 200, height: 120), outside: 0)
        var knock = pixel("Knockout deep", CGRect(x: 260, y: 260, width: 100, height: 80), "EF476F")
        knock.knockout = .deep
        knock.fillOpacity = 0
        var hidden = pixel("Hidden layer", CGRect(x: 380, y: 260, width: 100, height: 80), "000000")
        hidden.isVisible = false
        hidden.locks = LayerLocks(transparency: false, pixels: false, position: false, all: true)
        let empty = Layer(name: "Empty group", content: .group(GroupContent(children: [], isExpanded: false)))
        var pass = Layer(name: "Pass-through group", content: .group(GroupContent(children: [knock, hidden, empty], isExpanded: false)))
        pass.colorLabel = .red
        var linkA = pixel("Linked A", CGRect(x: 380, y: 250, width: 40, height: 20), "073B4C"), linkB = pixel("Linked B", CGRect(x: 440, y: 250, width: 40, height: 20), "073B4C")
        let lid = UUID()
        linkA.linkID = lid; linkB.linkID = lid
        st.layers += [masked, disabled, vmasked, blendIf, multiply, channels, group, pass, linkA, linkB]
        st.resolution = 300
        st.globalLight = GlobalLight(angle: 45, altitude: 50)
        st.guides = [Guide(isVertical: true, position: 260), Guide(isVertical: false, position: 180.5)]
        st.paths = [NamedPath(name: "Saved path", path: VectorPath.ellipse(CGRect(x: 100, y: 100, width: 80, height: 60))), NamedPath(name: "Work Path", path: VectorPath.rect(CGRect(x: 10, y: 10, width: 50, height: 50)))]
        let alpha = PixelBuffer(width: w, height: h, gray: 0)
        alpha.context.setFillColor(gray: 1, alpha: 1); alpha.context.fill(CGRect(x: 50, y: 50, width: 200, height: 100)); alpha.markDirty()
        st.alphaChannels = [AlphaChannel(name: "Selection A", buffer: alpha)]
        return st
    }

    static func artboards() -> DocumentState {
        var st = DocumentState(width: 700, height: 400)
        let a1 = Layer(name: "Artboard 1", content: .group(GroupContent(children: [
            shape("Card", .rectangle(CGRect(x: 40, y: 40, width: 220, height: 140), cornerRadius: 18), fill: .color(RGBA(hex: "4361EE")!)),
            text("Title", "Artboard one", font: "Helvetica-Bold", size: 26, at: CGPoint(x: 50, y: 220)),
        ], isExpanded: true, artboard: Artboard(rect: CGRect(x: 20, y: 20, width: 300, height: 360), background: .white))))
        let a2 = Layer(name: "Artboard 2", content: .group(GroupContent(children: [
            shape("Circle", .ellipse(CGRect(x: 420, y: 80, width: 180, height: 180)), fill: .color(RGBA(hex: "F72585")!)),
        ], isExpanded: true, artboard: Artboard(rect: CGRect(x: 360, y: 20, width: 320, height: 360), background: RGBA(hex: "FFF3B0")!))))
        st.layers = [a1, a2]
        return st
    }

    static func everything() -> DocumentState {
        var st = base(800, 600)
        let parts: [(DocumentState, CGPoint)] = [(fills(), CGPoint(x: 0, y: 0)), (shapes(), CGPoint(x: 0, y: 0)), (type(), CGPoint(x: 0, y: 0))]
        _ = parts
        let f = fills().layers.dropFirst(), sh = shapes().layers.dropFirst(), t = type().layers.dropFirst(), sm = smart().layers.dropFirst()
        func moved(_ ls: ArraySlice<Layer>, _ dx: Double, _ dy: Double, _ name: String, expanded: Bool = true) -> Layer {
            var g = Layer(name: name, content: .group(GroupContent(children: ls.map { var l = $0; l.translate(dx: dx, dy: dy, document: true); return l }, isExpanded: expanded)))
            g.blendMode = .passThrough
            return g
        }
        st.layers += [moved(f, 0, 0, "Fills"), moved(sh, 240, 240, "Shapes"), moved(t, 0, 200, "Type", expanded: false), moved(sm, 260, 0, "Smart objects")]
        st.layers += adjustments().layers.dropFirst().filter { $0.isAdjustment }.prefix(3)
        return st
    }

    /// Unusual documents the writer must survive.
    static func hostile() -> [(String, DocumentState)] {
        var out: [(String, DocumentState)] = []
        out.append(("no-layers", DocumentState(width: 64, height: 48)))
        var e = DocumentState(width: 64, height: 48)
        e.layers = [Layer(name: "", content: .group(GroupContent(children: []))), Layer.raster(name: "Transparent", width: 64, height: 48),
                    Layer.raster(name: "Off canvas", buffer: PixelBuffer(width: 10, height: 10, gray: 0), origin: IPoint(x: 500, y: 500))]
        out.append(("empty-and-offcanvas", e))
        var nan = DocumentState(width: 64, height: 48)
        var a = AdjustmentSettings(kind: .brightnessContrast); a.brightness = .nan; a.contrast = .infinity
        var lv = AdjustmentSettings(kind: .levels); lv.levels[0].gamma = .nan; lv.levels[1].inWhite = -.infinity
        var cv = AdjustmentSettings(kind: .curves); cv.curves[0].points = [CGPoint(x: CGFloat.nan, y: 0.5), CGPoint(x: 0.5, y: CGFloat.infinity)]
        var gm = AdjustmentSettings(kind: .gradientMap); gm.gradient.stops = [GradientStop(location: .nan, color: RGBA(r: .nan, g: 2, b: -1))]
        var t = TextContent(); t.fontSize = .nan; t.tracking = .infinity; t.text = ""; t.leading = .nan; t.transform = CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        var sl = Layer(name: "NaN shape", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), cornerRadius: .nan), fill: .color(RGBA(r: .nan, g: 0, b: 0)))))
        sl.opacity = .nan; sl.fillOpacity = -.infinity
        var so = SmartObjectContent(source: .image(PixelBuffer(width: 4, height: 4)), quad: Quad(tl: CGPoint(x: CGFloat.nan, y: 0), tr: .zero, br: .zero, bl: .zero))
        so.sourceName = ""
        nan.layers = [Layer(name: "NaN B/C", content: .adjustment(a)), Layer(name: "NaN levels", content: .adjustment(lv)), Layer(name: "NaN curves", content: .adjustment(cv)),
                      Layer(name: "NaN gradient map", content: .adjustment(gm)), Layer(name: "NaN text", content: .text(t)), sl,
                      Layer(name: "NaN smart object", content: .smartObject(so))]
        nan.resolution = .nan
        nan.globalLight = GlobalLight(angle: .nan, altitude: .infinity)
        nan.guides = [Guide(isVertical: true, position: .nan)]
        out.append(("nan-values", nan))
        var names = DocumentState(width: 32, height: 32)
        names.layers = [Layer.raster(name: String(repeating: "Ünïcødé 名前 🎨 ", count: 30), width: 32, height: 32), Layer.raster(name: "", width: 2, height: 2)]
        out.append(("long-unicode-names", names))
        var deep = DocumentState(width: 40, height: 40)
        var leaf = Layer.raster(name: "Leaf", width: 40, height: 40)
        leaf.raster?.buffer.context.setFillColor(RGBA.red.cgColor); leaf.raster?.buffer.context.fill(CGRect(x: 0, y: 0, width: 20, height: 20)); leaf.raster?.buffer.markDirty()
        var g = leaf
        for i in 0..<12 { g = Layer(name: "Group \(i)", content: .group(GroupContent(children: [g]))) }
        deep.layers = [g]
        out.append(("deep-nesting", deep))
        var tiny = DocumentState(width: 1, height: 1)
        tiny.layers = [Layer.raster(name: "One pixel", width: 1, height: 1), text("Text", "Hi", size: 40, at: .zero)]
        out.append(("one-pixel", tiny))
        var nested = DocumentState(width: 60, height: 60)
        var inner = DocumentState(width: 30, height: 30)
        inner.layers = [Layer.raster(name: "p", buffer: checker(30, 30))]
        for i in 0..<6 {
            var outer = DocumentState(width: 30, height: 30)
            outer.layers = [Layer(name: "SO \(i)", content: .smartObject(SmartObjectContent(source: .document(inner), quad: Quad(rect: CGRect(x: 0, y: 0, width: 30, height: 30)))))]
            inner = outer
        }
        nested.layers = inner.layers
        out.append(("nested-smart-objects", nested))
        return out
    }
}
