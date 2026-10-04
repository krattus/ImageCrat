import AppKit
import CoreText
import ImageCratCore

/// Settings of the "Editable layers" import.
struct PDFVectorOptions: Equatable {
    /// Text whose font is installed becomes a type layer (after checking that it lays out like the PDF).
    var editableText = true
    /// Text whose font is missing stays editable in a substitute font instead of being outlined (appearance changes).
    var substituteFonts = false
    /// Objects kept as layers before the rest of the page is rasterized in bands.
    var maxLayers = 1200
    /// Draw annotation appearances (form fields, stamps) like PDFKit does.
    var annotations = true
    /// Groups that Lumen would blend differently from the PDF (transparency inside a CMYK blending space, knockout
    /// groups) are compared with the PDF's rendering and rasterized when they differ visibly. Off: they stay layers.
    var exactAppearance = true
    var maxDimension = 16384
    var maxPixels = 80_000_000
}

/// Turns the interpreter's display list into layers.
final class PDFVectorBuilder {
    let interp: PDFVectorInterpreter
    let partial: PDFVectorPartial
    let options: PDFVectorOptions
    var report: PDFVectorReport
    let canvas: IRect

    private var palette: [RGBA] = []
    private var rampPages: [Int?] = []
    private var ramps: [Int: [GradientStop]] = [:]
    private var itemPages: [Int: Int] = [:]
    private var formPages: [Int: Int] = [:]
    private var maskPages: [Int] = []
    private var masks: [Int: LayerMask?] = [:]
    private var maskCount = 0
    static let maxVectorMasks = 160

    struct Resolved {
        var layers: [Layer]
        var bounds: CGRect
    }

    init(_ interp: PDFVectorInterpreter, options: PDFVectorOptions) {
        self.interp = interp
        self.options = options
        partial = PDFVectorPartial(interp)
        report = interp.report
        canvas = IRect(x: 0, y: 0, width: Int(interp.canvas.width), height: Int(interp.canvas.height))
    }

    static let blendModes: [String: BlendMode] = [
        "Multiply": .multiply, "Screen": .screen, "Overlay": .overlay, "Darken": .darken, "Lighten": .lighten, "ColorDodge": .colorDodge,
        "ColorBurn": .colorBurn, "HardLight": .hardLight, "SoftLight": .softLight, "Difference": .difference, "Exclusion": .exclusion,
        "Hue": .hue, "Saturation": .saturation, "Color": .color, "Luminosity": .luminosity,
    ]

    // MARK: Build

    /// Layers of the page, bottom first. Throws when the scratch PDF cannot be made (the page is then flattened).
    func build() throws -> [Layer] {
        partial.addPalette()
        rampPages = interp.gradients.map { partial.addRamp($0) }
        for (i, it) in interp.items.enumerated() {
            switch it.kind {
            case .raster(let r): itemPages[i] = partial.add(r.slice)
            case .text(let t): itemPages[i] = partial.add(t.slice)
            case .shape: break
            }
        }
        for (k, f) in interp.forms.enumerated() where f.needsCheck && options.exactAppearance { if let s = f.slice { formPages[k] = partial.add(s) } }
        if !options.exactAppearance, interp.forms.contains(where: { $0.needsCheck }) {
            report.note("Some transparency is blended in a CMYK colour space in the PDF; ImageCrat blends it in RGB, so those colours may differ slightly (exact appearance is off).")
        }
        maskPages = interp.softMasks.map { partial.addMask($0) }
        guard partial.finish() else { throw PDFVectorInterpreter.Abort.limit("its resources could not be copied") }
        palette = partial.paletteColors().map { RGBA(r: $0.r, g: $0.g, b: $0.b) }

        var resolved: [Int: Resolved] = [:]
        for i in interp.items.indices {
            if PDFVectorTextBuilder.debug, case .raster(let r) = interp.items[i].kind {
                let bytes = r.slice.synthetic ?? Array(interp.streams[r.slice.stream].bytes[r.slice.range])
                print("DEBUG raster \(i) \(r.reason) stream \(r.slice.stream) inText \(r.slice.inText): \(String(decoding: bytes.prefix(160), as: UTF8.self))")
                fflush(stdout)
            }
            if let r = resolve(i) { resolved[i] = r }
            if PDFVectorTextBuilder.debug {
                let it = interp.items[i]
                print("DEBUG item \(i) \(it.kind) ctx \(it.context) opacity \(it.opacity) blend \(it.blend) mask \(it.softMask.map(String.init) ?? "-") bounds \(it.bounds.integral) → \(resolved[i].map { "\($0.layers.count) layer(s)" } ?? "nothing")")
            }
        }
        let root = PDFVectorNode.build(interp.items)
        root.simplify(clips: interp.clips) { resolved[$0]?.bounds }
        report.mergedPaths = interp.items.reduce(0) { n, it in if case .shape(let sh) = it.kind { return n + sh.parts.count }; return n }
        let layers = self.layers(root, resolved)
        report.layerNames = interp.ocgs.map(\.name)
        return layers
    }

    private func color(_ p: PDFVectorPaint) -> RGBA? {
        if case .color(let i) = p, i < palette.count { return palette[i] }
        return nil
    }

    private func resolve(_ i: Int) -> Resolved? {
        let it = interp.items[i]
        switch it.kind {
        case .shape(let sh):
            guard var layer = shapeLayer(sh) else { return nil }
            apply(it, to: &layer)
            if let m = it.softMask {
                guard let mask = softMask(m) else { return nil }   // the mask hides everything
                layer.mask = mask
                report.softMasks += 1
            }
            report.shapes += 1
            return Resolved(layers: [layer], bounds: sh.unionBounds)
        case .raster(let r):
            guard let page = itemPages[i], var (layer, b) = rasterLayer(page: page, bounds: it.bounds, name: r.isImage ? r.name : "\(r.name) (rasterized)") else {
                if r.isImage { report.images = max(0, report.images - 1) }
                return nil
            }
            apply(it, to: &layer)
            return Resolved(layers: [layer], bounds: b)
        case .text(let t):
            guard let page = itemPages[i] else { return nil }
            return PDFVectorTextBuilder(builder: self).resolve(t, item: it, page: page)
        }
    }

    func apply(_ it: PDFVectorItem, to layer: inout Layer) {
        layer.opacity = max(0, min(1, it.opacity))
        if let m = PDFVectorBuilder.blendModes[it.blend] { layer.blendMode = m }
    }

    // MARK: Shapes

    func paintStyle(_ p: PDFVectorPaint) -> PaintStyle {
        switch p {
        case .empty: return .none
        case .color: return color(p).map { .color($0) } ?? .none
        case .gradient(let g): return gradientFill(g).map { .gradient($0) } ?? .none
        }
    }

    private func gradientFill(_ index: Int) -> GradientFill? {
        let g = interp.gradients[index]
        guard index < rampPages.count, let page = rampPages[index] else { return nil }
        if ramps[page] == nil, let samples = partial.ramp(page) { ramps[page] = PDFVectorBuilder.stops(samples, inner: g.innerFraction) }
        guard let stops = ramps[page], !stops.isEmpty else { return nil }
        var f = GradientFill(gradient: ColorGradient(name: "PDF Gradient", stops: stops), type: g.radial ? .radial : .linear)
        f.start = g.start
        f.end = g.end
        f.dither = false
        return f
    }

    /// Fewest stops that reproduce 256 ramp samples to within a level or so; positions are squeezed into
    /// `inner…1` for a radial shading that starts on a circle.
    static func stops(_ s: [(r: Double, g: Double, b: Double)], inner: Double) -> [GradientStop] {
        guard s.count >= 2 else { return [] }
        let n = s.count
        func fits(_ a: Int, _ b: Int) -> Bool {
            guard b > a + 1 else { return true }
            let tol = 1.6 / 255
            for k in (a + 1)..<b {
                let t = Double(k - a) / Double(b - a)
                if abs(s[a].r + (s[b].r - s[a].r) * t - s[k].r) > tol || abs(s[a].g + (s[b].g - s[a].g) * t - s[k].g) > tol
                    || abs(s[a].b + (s[b].b - s[a].b) * t - s[k].b) > tol { return false }
            }
            return true
        }
        var idx = [0]
        var a = 0
        while a < n - 1 {
            var b = a + 1
            while b + 1 < n, fits(a, b + 1) { b += 1 }
            idx.append(b)
            a = b
        }
        return idx.map { k in
            GradientStop(location: inner + (1 - inner) * Double(k) / Double(n - 1), color: RGBA(r: s[k].r, g: s[k].g, b: s[k].b))
        }
    }

    private func shapeLayer(_ sh: PDFVectorShape) -> Layer? {
        var cg = sh.path
        let strokeOnly = sh.stroke != nil && sh.fill == .empty
        // Several closed outlines in one stroked shape would be united by the shape renderer: open them.
        if strokeOnly, sh.closedSubpaths > 1 { cg = PDFVectorGeometry.openingClosedSubpaths(cg) }
        var geometry: ShapeGeometry
        // (a dashed outline stays a path: a rectangle shape starts its dashes at another corner)
        if sh.parts.count == 1, let r = PDFVectorGeometry.axisAlignedRect(cg), sh.stroke == nil || (sh.closedSubpaths == 1 && sh.stroke!.dash.isEmpty) {
            geometry = .rectangle(r, cornerRadius: 0)
        } else {
            var vp = PDFVectorGeometry.vectorPath(cg)
            if sh.stroke == nil { for k in vp.subpaths.indices { vp.subpaths[k].closed = true } }   // a fill closes its subpaths
            if vp.subpaths.isEmpty { return nil }
            geometry = .path(vp)
        }
        var sc = ShapeContent(geometry: geometry, fill: paintStyle(sh.fill))
        if let st = sh.stroke {
            let w = max(0.01, st.width)
            sc.stroke = StrokeStyle(paint: paintStyle(sh.strokePaint), width: w, alignment: .center,
                                    cap: [.butt, .round, .square][max(0, min(2, st.cap))], join: [.miter, .round, .bevel][max(0, min(2, st.join))],
                                    dash: st.dash.map { $0 / w })
        }
        if sc.fill.isNone && sc.stroke.paint.isNone { return nil }
        var name = sh.label
        if sh.parts.count > 1 { name = "\(sh.parts.count) Paths" }
        return Layer(name: name, content: .shape(sc))
    }

    // MARK: Pixels from the PDF

    /// Renders a scratch page over `bounds` and trims it to what was painted.
    func rasterLayer(page: Int, bounds: CGRect, name: String) -> (Layer, CGRect)? {
        let r = IRect(enclosing: bounds.insetBy(dx: -1, dy: -1)).intersection(canvas)
        guard !r.isEmpty, r.width * r.height <= 120_000_000 else { return nil }
        let buf = PixelBuffer(width: r.width, height: r.height)
        let ctx = buf.context
        ctx.saveGState()
        ctx.translateBy(x: -CGFloat(r.x), y: -CGFloat(r.y))
        partial.draw(page, in: ctx)
        ctx.restoreGState()
        buf.markDirty()
        guard let ob = buf.opaqueBounds() else { return nil }
        let trimmed = ob == buf.bounds ? buf : buf.cropped(to: ob)
        let origin = IPoint(x: r.x + ob.x, y: r.y + ob.y)
        let b = CGRect(x: origin.x, y: origin.y, width: ob.width, height: ob.height)
        return (Layer.raster(name: name, buffer: trimmed, origin: origin), b)
    }

    // MARK: Tree

    private func layers(_ node: PDFVectorNode, _ resolved: [Int: Resolved]) -> [Layer] {
        var out: [Layer] = []
        for c in node.children {
            switch c.kind {
            case .root: break
            case .item(let i): out += resolved[i]?.layers ?? []
            case .ocg(let k):
                let kids = layers(c, resolved)
                guard !kids.isEmpty else { continue }
                var g = Layer(name: interp.ocgs[k].name, content: .group(GroupContent(children: kids, isExpanded: kids.count <= 40)))
                g.isVisible = interp.ocgs[k].visible
                report.groups += 1
                out.append(g)
            case .form(let k):
                let f = interp.forms[k]
                var kids = layers(c, resolved)
                guard !kids.isEmpty else { continue }
                if f.needsCheck, let page = formPages[k], let flat = verifiedGroup(f, kids: kids, page: page) {
                    out.append(flat)
                    continue
                }
                let mode = PDFVectorBuilder.blendModes[f.blend]
                var groupMask: LayerMask? = nil
                if let m = f.softMask {
                    guard let mask = softMask(m) else { continue }   // the mask hides the whole group
                    groupMask = mask
                }
                if let groupMask {
                    // a group drawn through a soft mask: the mask applies to the group as a whole
                    var g = Layer(name: "Group", content: .group(GroupContent(children: kids, isExpanded: false)))
                    g.mask = groupMask
                    g.opacity = f.opacity
                    g.blendMode = mode ?? .normal
                    report.groups += 1
                    report.softMasks += 1
                    out.append(g)
                    continue
                }
                let plain = !f.isGroup || (f.opacity >= 0.999 && mode == nil)
                if plain && (kids.count == 1 || !f.isGroup && kids.count <= 1) { out += kids; continue }
                if !plain, kids.count == 1, kids[0].opacity >= 0.999, kids[0].blendMode == .normal || kids[0].blendMode == .passThrough {
                    // a group around one object: the object takes the group's opacity and blend mode
                    kids[0].opacity = f.opacity
                    if let mode { kids[0].blendMode = mode } else if kids[0].isGroup, f.isolated { kids[0].blendMode = .normal }
                    out.append(kids[0])
                    continue
                }
                var g = Layer(name: f.name == "Annotation" ? "Annotation" : "Group", content: .group(GroupContent(children: kids, isExpanded: false)))
                g.opacity = f.isGroup ? f.opacity : 1
                g.blendMode = mode ?? (f.isGroup && f.isolated ? .normal : .passThrough)
                report.groups += 1
                out.append(g)
            case .clip(let k):
                var kids = layers(c, resolved)
                guard !kids.isEmpty else { continue }
                let clip = interp.clips[k]
                maskCount += 1
                if maskCount > PDFVectorBuilder.maxVectorMasks {
                    // many full-canvas vector masks are heavy: beyond the limit the clip becomes a small pixel mask
                    report.note("The page has more than \(PDFVectorBuilder.maxVectorMasks) clipping paths; the rest became pixel masks.")
                    let m = pixelMask(clip)
                    if kids.count == 1, kids[0].mask == nil { kids[0].mask = m; out.append(kids[0]); continue }
                    var g = Layer(name: "Clip Group", content: .group(GroupContent(children: kids, isExpanded: false)))
                    g.mask = m
                    out.append(g)
                    continue
                }
                var vp = PDFVectorGeometry.vectorPath(clip.path)
                for s in vp.subpaths.indices { vp.subpaths[s].closed = true }
                report.masks += 1
                if kids.count == 1, kids[0].vectorMask == nil, kids[0].mask == nil {
                    kids[0].vectorMask = vp
                    out.append(kids[0])
                } else {
                    var g = Layer(name: "Clip Group", content: .group(GroupContent(children: kids, isExpanded: false)))
                    g.vectorMask = vp
                    report.groups += 1
                    out.append(g)
                }
            }
        }
        return out
    }

    /// The soft mask as a layer mask (nil when it is black everywhere). Layers painted through the same mask share
    /// one buffer; layer masks are never edited in place.
    private func softMask(_ index: Int) -> LayerMask? {
        if let m = masks[index] { return m }
        var result: LayerMask? = nil
        if index < maskPages.count, canvas.width * canvas.height <= 120_000_000 {
            let buf = PixelBuffer(width: canvas.width, height: canvas.height)
            partial.draw(maskPages[index], in: buf.context)
            buf.markDirty()
            if let ob = buf.opaqueBounds() {
                // white through the mask: its alpha is the mask
                let gray = PixelBuffer(width: ob.width, height: ob.height, gray: 0)
                let src = buf.data.assumingMemoryBound(to: UInt8.self), dst = gray.data.assumingMemoryBound(to: UInt8.self)
                for y in 0..<ob.height {
                    for x in 0..<ob.width { dst[y * gray.bytesPerRow + x] = src[(y + ob.y) * buf.bytesPerRow + (x + ob.x) * 4 + 3] }
                }
                gray.markDirty()
                result = LayerMask(buffer: gray, origin: IPoint(x: ob.x, y: ob.y), outsideValue: 0)
            }
        }
        masks[index] = .some(result)
        if PDFVectorTextBuilder.debug { print("DEBUG soft mask \(index) ctm \(interp.softMasks[index].ctm) → \(result.map { "\($0.buffer.width)×\($0.buffer.height) at \($0.origin)" } ?? "empty")") }
        return result
    }

    private func pixelMask(_ clip: PDFVectorClip) -> LayerMask {
        let r = IRect(enclosing: clip.bounds).intersection(canvas)
        let w = max(1, r.width), h = max(1, r.height)
        let buf = PixelBuffer(width: w, height: h, gray: 0)
        let ctx = buf.context
        ctx.saveGState()
        ctx.translateBy(x: -CGFloat(r.x), y: -CGFloat(r.y))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(clip.path)
        ctx.fillPath()
        ctx.restoreGState()
        buf.markDirty()
        return LayerMask(buffer: buf, origin: r.origin, outsideValue: 0)
    }

    /// A transparency group whose blending Lumen cannot reproduce exactly (it blends in a CMYK space, or knocks
    /// out): the rebuilt layers are composited and compared with the PDF's own rendering of the group. Returns a
    /// pixel layer when they differ visibly, nil to keep the layers.
    private func verifiedGroup(_ f: PDFVectorFormInstance, kids: [Layer], page: Int) -> Layer? {
        guard let slice = f.slice else { return nil }
        _ = slice
        let region = canvas
        guard region.width * region.height <= 40_000_000 else { return nil }
        let ref = PixelBuffer(width: region.width, height: region.height)
        partial.draw(page, in: ref.context)
        ref.markDirty()
        guard let ob = ref.opaqueBounds() else { return nil }
        var st = DocumentState(width: region.width, height: region.height)
        st.layers = kids
        guard let cg = Compositor.shared.flatten(st) else { return nil }
        let mine = PixelBuffer(cgImage: cg)
        // mean difference over the group's pixels
        let a = ref.data.assumingMemoryBound(to: UInt8.self), b = mine.data.assumingMemoryBound(to: UInt8.self)
        var total = 0, count = 0, bad = 0
        for y in ob.y..<(ob.y + ob.height) {
            for x in ob.x..<(ob.x + ob.width) {
                let i = y * ref.bytesPerRow + x * 4, j = y * mine.bytesPerRow + x * 4
                if a[i + 3] == 0 && b[j + 3] == 0 { continue }
                var d = 0
                for c in 0..<4 { d += abs(Int(a[i + c]) - Int(b[j + c])) }
                total += d
                count += 4
                if d > 48 { bad += 1 }
            }
        }
        guard count > 0 else { return nil }
        let mean = Double(total) / Double(count)
        if mean < 1.5 && Double(bad) / Double(count / 4) < 0.02 { return nil }
        let trimmed = ob == ref.bounds ? ref : ref.cropped(to: ob)
        var layer = Layer.raster(name: "Group (rasterized)", buffer: trimmed, origin: IPoint(x: ob.x, y: ob.y))
        layer.opacity = f.opacity
        if let m = PDFVectorBuilder.blendModes[f.blend] { layer.blendMode = m }
        report.raster(f.checkReason)
        return layer
    }
}
