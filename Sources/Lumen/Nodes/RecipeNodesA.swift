import Foundation
import CoreImage
import CoreGraphics
import ImageCratCore

/// Decoded image files for the Image File node (keyed by path + modification date).
enum RecipeImageCache {
    private static var cache: [String: (Date?, CIImage)] = [:]
    private static let lock = NSLock()

    static func image(_ path: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let c = cache[url.path], c.0 == mod { return c.1 }
        guard FileManager.default.fileExists(atPath: url.path), let (cg, _) = DocumentIO.loadImage(url: url) else { return nil }
        let img = CIImage(cgImage: cg)
        cache[url.path] = (mod, img)
        if cache.count > 24, let k = cache.keys.first(where: { $0 != url.path }) { cache.removeValue(forKey: k) }
        return img
    }
}

/// Numeric fields of `AdjustmentSettings` that Adjust nodes expose as sliders / sockets.
struct RecipeAdjustKey {
    let key: String
    let label: String
    let range: ClosedRange<Double>
    let get: (AdjustmentSettings) -> Double
    let set: (inout AdjustmentSettings, Double) -> Void

    static func kp(_ key: String, _ label: String, _ r: ClosedRange<Double>, _ p: WritableKeyPath<AdjustmentSettings, Double>) -> RecipeAdjustKey {
        RecipeAdjustKey(key: key, label: label, range: r, get: { $0[keyPath: p] }, set: { $0[keyPath: p] = $1 })
    }

    static func keys(_ k: AdjustmentKind) -> [RecipeAdjustKey] {
        switch k {
        case .brightnessContrast: return [kp("brightness", "Brightness", -150...150, \.brightness), kp("contrast", "Contrast", -50...100, \.contrast)]
        case .exposure: return [kp("exposure", "Exposure", -5...5, \.exposure), kp("offset", "Offset", -0.5...0.5, \.offset), kp("gamma", "Gamma", 0.1...5, \.gamma)]
        case .vibrance: return [kp("vibrance", "Vibrance", -100...100, \.vibrance), kp("saturation", "Saturation", -100...100, \.saturation)]
        case .hueSaturation: return [kp("hue", "Hue", -180...180, \.hue), kp("hsSaturation", "Saturation", -100...100, \.hsSaturation), kp("lightness", "Lightness", -100...100, \.lightness)]
        case .photoFilter: return [kp("density", "Density", 0...100, \.density)]
        case .posterize: return [kp("posterizeLevels", "Levels", 2...64, \.posterizeLevels)]
        case .threshold: return [kp("thresholdLevel", "Level", 1...255, \.thresholdLevel)]
        case .shadowsHighlights: return [kp("shAmountShadows", "Shadows", 0...100, \.shAmountShadows), kp("shAmountHighlights", "Highlights", 0...100, \.shAmountHighlights),
                                         kp("shRadius", "Radius", 0...100, \.shRadius)]
        case .blackWhite: return [kp("bwReds", "Reds", -200...300, \.bwReds), kp("bwYellows", "Yellows", -200...300, \.bwYellows), kp("bwGreens", "Greens", -200...300, \.bwGreens),
                                  kp("bwCyans", "Cyans", -200...300, \.bwCyans), kp("bwBlues", "Blues", -200...300, \.bwBlues), kp("bwMagentas", "Magentas", -200...300, \.bwMagentas)]
        case .levels: return [
            RecipeAdjustKey(key: "inBlack", label: "Input Black", range: 0...253, get: { $0.levels[0].inBlack }, set: { $0.levels[0].inBlack = $1 }),
            RecipeAdjustKey(key: "inWhite", label: "Input White", range: 2...255, get: { $0.levels[0].inWhite }, set: { $0.levels[0].inWhite = $1 }),
            RecipeAdjustKey(key: "levelsGamma", label: "Gamma", range: 0.1...9.99, get: { $0.levels[0].gamma }, set: { $0.levels[0].gamma = $1 }),
            RecipeAdjustKey(key: "outBlack", label: "Output Black", range: 0...255, get: { $0.levels[0].outBlack }, set: { $0.levels[0].outBlack = $1 }),
            RecipeAdjustKey(key: "outWhite", label: "Output White", range: 0...255, get: { $0.levels[0].outWhite }, set: { $0.levels[0].outWhite = $1 })]
        case .colorWB, .clarity, .dehaze, .grain, .light:
            return EditsAdjustments.params(k).map { p in
                RecipeAdjustKey(key: p.key, label: p.label, range: p.range, get: { $0.params[p.key] ?? p.def }, set: { $0.params[p.key] = $1 })
            }
        default: return []
        }
    }

    /// Node settings with the node's numeric parameters applied.
    static func settings(_ node: RecipeNode, kind: AdjustmentKind, value: ((String) -> Double)? = nil) -> AdjustmentSettings {
        var s = node.adjustment ?? AdjustmentSettings(kind: kind)
        if s.kind != kind { s = AdjustmentSettings(kind: kind) }
        for k in keys(kind) {
            if let v = value { k.set(&s, v(k.key)) } else if let n = node.numbers[k.key] { k.set(&s, n) }
        }
        return s
    }

    /// Writes settings edited through the full adjustment UI back into a node (keeping numbers in sync).
    static func store(_ s: AdjustmentSettings, in node: inout RecipeNode) {
        node.adjustment = s
        for k in keys(s.kind) { node.numbers[k.key] = k.get(s) }
    }
}

extension RecipeLibrary {
    private typealias P = RecipeParamSpec
    private static let image = RecipePortSpec("Image", .image)

    // MARK: Input

    static let inputNodes: [RecipeNodeSpec] = [
        RecipeNodeSpec(type: "in.source", name: "Layer Below", category: .input,
                       outputs: [RecipePortSpec("Image", .image), RecipePortSpec("Alpha", .mask)], uses: .source,
                       keywords: ["composite below", "source", "input", "backdrop", "smart object", "content"]) { ev in
            let img = RecipeEvaluator.fit(ev.ctx.source ?? ev.clear, ev.canvas, opaqueBlack: false)
            ev.out = [.image(img), .mask(RecipeKernels.toMask?.apply(extent: ev.canvas, arguments: [img, 4]) ?? img)]
        },
        RecipeNodeSpec(type: "in.layer", name: "Layer", category: .input,
                       outputs: [RecipePortSpec("Image", .image), RecipePortSpec("Alpha", .mask)],
                       params: [.layer("layer", "Layer"), .choice("mode", "Use", ["Appearance (effects, mask)", "Content Only"], 0)],
                       uses: .document, keywords: ["reference", "other layer", "live"]) { ev in
            guard let st = ev.ctx.state else { throw RecipeError.message("No document") }
            guard let id = UUID(uuidString: ev.string("layer")) else { throw RecipeError.message("Choose a layer") }
            guard let l = st.layer(id) else { throw RecipeError.message("Layer not found") }
            if id == ev.ctx.layerID { throw RecipeError.message("A recipe can't read its own layer") }
            let img = RecipeEvaluator.fit(try RecipeRuntime.layerImage(l, state: st, space: ev.ctx.space, contentOnly: ev.int("mode") == 1), ev.canvas, opaqueBlack: false)
            ev.out = [.image(img), .mask(RecipeKernels.toMask?.apply(extent: ev.canvas, arguments: [img, 4]) ?? img)]
        },
        RecipeNodeSpec(type: "in.file", name: "Image File", category: .input,
                       params: [.file("path", "File"), .choice("fit", "Fit", ["Fit", "Fill", "Stretch", "Original Size", "Tile"], 1)],
                       keywords: ["picture", "photo", "texture", "load"]) { ev in
            let path = ev.string("path")
            if path.isEmpty { throw RecipeError.message("Choose an image file") }
            guard let src = RecipeImageCache.image(path) else { throw RecipeError.message("File not found: \((path as NSString).lastPathComponent)") }
            let c = ev.canvas, e = src.extent
            let sx = c.width / max(1, e.width), sy = c.height / max(1, e.height)
            var img: CIImage
            switch ev.int("fit") {
            case 0, 1:
                let s = ev.int("fit") == 0 ? min(sx, sy) : max(sx, sy)
                img = src.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
                img = img.translated(c.midX - img.extent.midX, c.midY - img.extent.midY)
            case 2: img = src.transformed(by: CGAffineTransform(scaleX: sx, y: sy), highQualityDownsample: true)
            case 3: img = src.translated(c.midX - e.midX, c.midY - e.midY)
            default: img = TextureEngine.tiled(src.translated(0, c.maxY - e.height))
            }
            ev.set(img.cropped(to: c))
        },
        RecipeNodeSpec(type: "in.solid", name: "Solid Color", category: .input, params: [.color("color", "Color", RGBA(hex: "4A90E2")!)], keywords: ["fill", "flat"]) { ev in
            let c = ev.color("color")
            ev.set(RecipeKernels.constant(c.r, c.g, c.b, c.a, ev.canvas))
        },
        RecipeNodeSpec(type: "in.gradient", name: "Gradient", category: .input,
                       params: [.gradient("gradient", "Gradient", .twoColor(.black, .white, name: "Black, White")),
                                .choice("type", "Type", GradientType.allCases.map(\.displayName), 0), .angle("angle", "Angle", 0),
                                .slider("scale", "Scale", 0.05...3, 1), .point("center", "Center"), .toggle("reverse", "Reverse", false)],
                       keywords: ["ramp", "linear", "radial"]) { ev in
            var gf = GradientFill(gradient: ev.gradient("gradient"))
            gf.type = GradientType.allCases[min(max(0, ev.int("type")), GradientType.allCases.count - 1)]
            gf.angle = ev.num("angle"); gf.scale = ev.num("scale"); gf.reverse = ev.bool("reverse")
            let sp = ev.ctx.space
            let bounds = CGRect(x: 0, y: 0, width: sp.width, height: sp.height)
            var (s, e) = gf.endpoints(in: bounds)
            let c = ev.point("center")
            let shift = CGPoint(x: (c.x - 0.5) * bounds.width + ev.ctx.origin.x, y: (c.y - 0.5) * bounds.height + ev.ctx.origin.y)
            s = s + shift; e = e + shift
            ev.set(Kernels.gradientImage(gf.gradient, type: gf.type, p0: sp.ciPoint(s), p1: sp.ciPoint(e), reverse: gf.reverse, extent: ev.canvas))
        },
        RecipeNodeSpec(type: "in.uv", name: "Canvas Coordinates", category: .input,
                       outputs: [RecipePortSpec("UV", .image), RecipePortSpec("U", .mask), RecipePortSpec("V", .mask)],
                       params: [.choice("mode", "Mode", ["Normalized (0…1)", "Distance from Center", "Polar (angle, radius)"], 0)],
                       keywords: ["uv", "position", "xy", "coordinates"]) { ev in
            let c = ev.canvas
            let o = ev.ctx.origin
            guard let k = RecipeKernels.uv, let uv = k.apply(extent: c, roiCallback: { _, r in r },
                                                                arguments: [CIVector(x: c.width, y: c.height, z: c.minX + o.x, w: c.minY - o.y), Float(ev.int("mode"))]) else {
                throw RecipeError.message("Kernel unavailable")
            }
            let u = RecipeKernels.toMask?.apply(extent: c, arguments: [uv, 1]) ?? uv
            let v = RecipeKernels.toMask?.apply(extent: c, arguments: [uv, 2]) ?? uv
            ev.out = [.image(uv), .mask(u), .mask(v)]
        },
        RecipeNodeSpec(type: "in.selection", name: "Selection", category: .input, outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.choice("empty", "When Nothing Is Selected", ["White (everything)", "Black (nothing)"], 0)],
                       uses: .document, keywords: ["marquee", "selected"]) { ev in
            if let sel = ev.ctx.state?.selection {
                ev.setMask(ev.ctx.space.place(sel, at: .zero).composited(over: CIImage.color(.black, ev.canvas)))
            } else {
                ev.setMask(CIImage.color(ev.int("empty") == 0 ? .white : .black, ev.canvas))
            }
        },
        RecipeNodeSpec(type: "in.mask", name: "Layer Mask", category: .input, outputs: [RecipePortSpec("Mask", .mask)],
                       params: [.layer("layer", "Layer (empty = this layer)")], uses: .document, keywords: ["mask"]) { ev in
            guard let st = ev.ctx.state else { throw RecipeError.message("No document") }
            let id = UUID(uuidString: ev.string("layer")) ?? ev.ctx.layerID
            guard let lid = id, let l = st.layer(lid) else { throw RecipeError.message("Layer not found") }
            guard let m = Compositor.shared.maskImage(l, space: ev.ctx.space) else { ev.setMask(CIImage.color(.white, ev.canvas)); return }
            ev.setMask(m.cropped(to: ev.canvas))
        },
        RecipeNodeSpec(type: "in.time", name: "Time", category: .input,
                       outputs: [RecipePortSpec("Seconds", .number), RecipePortSpec("Frame", .number), RecipePortSpec("Cycle", .number)],
                       params: [.slider("speed", "Speed", -10...10, 1), .slider("offset", "Offset", -100...100, 0), .slider("fps", "Frame Rate", 1...120, 30),
                                .slider("loop", "Loop Length (s, 0 = off)", 0...600, 0)],
                       uses: .time, keywords: ["animation", "clock", "frame", "timeline"]) { ev in
            var t = ev.ctx.time * ev.num("speed") + ev.num("offset")
            let loop = ev.num("loop")
            var cycle = 0.0
            if loop > 0.0001 { t = t - loop * floor(t / loop); cycle = t / loop }
            ev.out = [.number(t), .number((t * ev.num("fps")).rounded(.down)), .number(cycle)]
        },
    ]

    // MARK: Generate (procedural textures)

    static func texParams(_ g: TextureGen) -> [RecipeParamSpec] {
        func conv(_ p: TexParam, advanced: Bool) -> RecipeParamSpec {
            var s: RecipeParamSpec
            switch p.kind {
            case .slider(let r): s = .slider(p.key, p.label, r, p.def)
            case .int(let r): s = p.key == "seed" ? .seed("seed", "Seed", p.def) : .int(p.key, p.label, r, p.def)
            case .toggle: s = .toggle(p.key, p.label, p.def > 0.5)
            case .choice(let o): s = .choice(p.key, p.label, o, Int(p.def))
            }
            if p.key == "scale" { s.unit = "px" }
            if p.key == "rotation" { s = .angle("rotation", "Rotation", p.def) }
            s.advanced = advanced
            return s
        }
        let common = TextureCatalog.commonParams(g)
        let front = ["scale", "rotation", "seed"], back = ["contrast", "invert", "tileable"]
        var out: [RecipeParamSpec] = []
        for k in front { if let p = common.first(where: { $0.key == k }) { out.append(conv(p, advanced: false)) } }
        for p in g.params { out.append(conv(p, advanced: false)) }
        for c in g.colors { out.append(.color(c.key, c.label, c.def)) }
        var ramp = RecipeParamSpec.gradient("ramp", g.direct ? "Gradient (when mapped)" : "Color Ramp", g.ramp)
        ramp.advanced = g.direct
        out.append(ramp)
        for k in back { if let p = common.first(where: { $0.key == k }) { out.append(conv(p, advanced: false)) } }
        for p in common where !front.contains(p.key) && !back.contains(p.key) { out.append(conv(p, advanced: true)) }
        return out
    }

    /// Texture settings of a generator node (through `value` so wires can drive parameters).
    static func textureSettings(_ g: TextureGen, number: (String) -> Double, color: (String) -> RGBA, ramp: ColorGradient) -> TextureSettings {
        var s = TextureSettings(gen: g.id)
        for p in TextureCatalog.commonParams(g) + g.params { s.values[p.key] = number(p.key) }
        for c in g.colors { s.colors[c.key] = color(c.key) }
        s.ramp = ramp
        return s
    }

    static let generatorNodes: [RecipeNodeSpec] = TextureCatalog.all.map { g in
        RecipeNodeSpec(type: "gen." + g.id, name: g.name, category: .generate, group: g.category.rawValue,
                       params: texParams(g), keywords: g.keywords + ["texture", "procedural", "generator"]) { ev in
            let s = textureSettings(g, number: { ev.num($0) }, color: { ev.color($0) }, ramp: ev.gradient("ramp"))
            ev.set(TextureEngine.render(s, space: ev.ctx.space, origin: ev.ctx.origin))
        }
    }

    // MARK: Adjust

    static let adjustNodes: [RecipeNodeSpec] = AdjustmentKind.allCases.filter { $0 != .matchColor }.map { kind in
        let keys = RecipeAdjustKey.keys(kind)
        var params: [RecipeParamSpec] = keys.map { k in RecipeParamSpec.slider(k.key, k.label, k.range, k.get(AdjustmentSettings(kind: kind))) }
        if kind == .gradientMap {
            params.append(.gradient("gradient", "Gradient", .twoColor(.black, .white, name: "Black, White")))
            params.append(.toggle("reverse", "Reverse", false))
        }
        return RecipeNodeSpec(type: "adj." + kind.rawValue, name: kind.displayName, category: .adjust, inputs: [image], params: params,
                              keywords: ["adjustment", "color", "tone"], bypass: "Image", adjustmentKind: kind) { ev in
            let img = try ev.need()
            let e = ev
            var s = RecipeAdjustKey.settings(ev.node, kind: kind, value: { e.num($0) })
            if kind == .gradientMap { s.gradient = ev.gradient("gradient"); s.gradientReverse = ev.bool("reverse") }
            ev.set(AdjustmentEngine.apply(s, to: img))
        }
    }

    // MARK: Filter (every FilterKind)

    private static func filterParams(_ params: [FilterParam]) -> [RecipeParamSpec] {
        params.map { p in
            var s: RecipeParamSpec
            switch p.kind {
            case .slider(let r): s = .slider(p.key, p.label, r, p.defaultValue, unit: p.unit)
            case .angle: s = .angle(p.key, p.label, p.defaultValue)
            case .toggle: s = .toggle(p.key, p.label, p.defaultValue > 0.5)
            case .choice(let o): s = .choice(p.key, p.label, o, Int(p.defaultValue))
            case .percentPoint: s = .slider(p.key, p.label, 0...1, p.defaultValue)
            }
            return s
        }
    }

    /// Recipe filter nodes' Center choice (0 = the node's point, 1 = the input's object).
    static let centerOnKey = "centerOn"

    static let filterNodes: [RecipeNodeSpec] = FilterKind.allCases.filter { $0 != .neuralFilter && $0 != .recipe && $0 != .filterGallery && $0 != .liquify }.map { kind in
        var params = filterParams(kind.params)
        var inputs = [image]
        if kind.usesColors || kind == .pointillize {
            params.append(.color("fg", "Foreground", .black)); params.append(.color("bg", "Background", .white))
        }
        switch kind {
        case .gaussianBlur: params.append(.toggle("clampEdges", "Extend Edges (no dark border)", true))
        case .displace: inputs.append(RecipePortSpec("Map", .image))
        case .fieldBlur, .irisBlur: params.append(.point("center", "Center"))
        case .pathBlur: params.append(.point("start", "Path Start", CGPoint(x: 0.3, y: 0.5))); params.append(.point("end", "Path End", CGPoint(x: 0.7, y: 0.5)))
        default: break
        }
        // Center option (FilterCenter.swift): the node's own point (Center X / Y, else the canvas middle) or the middle
        // of its input's pixels, the radius then sized from them. "Point" first: graphs saved before keep their look.
        if kind.usesCenter { params.append(.choice(centerOnKey, "Center", ["Point", "Object"], 0)) }
        let generator = kind == .clouds
        return RecipeNodeSpec(type: "filter." + kind.rawValue, name: kind.displayName, category: .filter, group: kind.category.rawValue,
                              inputs: inputs, params: params, keywords: ["filter", kind.category.rawValue.lowercased()], bypass: "Image") { ev in
            let img: CIImage
            if generator { img = ev.image() ?? CIImage.color(.white, ev.canvas) } else { img = try ev.need() }
            var inst = FilterInstance(kind: kind, colors: [ev.color("fg"), ev.color("bg")])
            for p in kind.params { inst.values[p.key] = ev.num(p.key) }
            switch kind {
            case .gaussianBlur where ev.bool("clampEdges"):
                // the stock filter blurs against transparency, which darkens the canvas border
                ev.set(img.blurred(ev.num("radius"), clampTo: ev.canvas))
                return
            case .displace:
                // FilterExtras.displace takes its map from a pixel buffer; use the live kernel with the Map input instead.
                guard let map = ev.image("Map"), let k = FilterExtras.displaceKernel else { throw RecipeError.missingInput("Map") }
                let hs = Float(ev.num("h") / 100 * 128), vs = Float(ev.num("v") / 100 * 128)
                let out = k.apply(extent: ev.canvas, roiCallback: { i, r in i == 0 ? r.insetBy(dx: -CGFloat(abs(hs)) - 2, dy: -CGFloat(abs(vs)) - 2) : r },
                                  arguments: [img.clampedToExtent(), map.clampedToExtent(), hs, vs])
                ev.set(out ?? img)
                return
            case .fieldBlur:
                let c = ev.point("center")
                inst.points = [FilterPin(x: c.x, y: c.y, value: ev.num("blur"))]
            case .irisBlur:
                let c = ev.point("center")
                inst.points = [FilterPin(x: c.x, y: c.y, value: 0)]
            case .pathBlur:
                let a = ev.point("start"), b = ev.point("end")
                inst.points = [FilterPin(x: a.x, y: a.y, value: 0), FilterPin(x: b.x, y: b.y, value: 0)]
            default: break
            }
            if kind.usesCenter && ev.int(centerOnKey) == 1, let ob = FilterCenterResolver.alphaBounds(img, canvas: ev.canvas) {
                inst.resolveCenter(FilterCenterContext(canvasWidth: Double(ev.canvas.width), canvasHeight: Double(ev.canvas.height), object: ob), mode: .object)
            }
            ev.set(inst.apply(img, canvas: ev.canvas))
        }
    }

    // MARK: Filter Gallery looks

    static let galleryNodes: [RecipeNodeSpec] = GalleryFilter.allCases.map { gf in
        var params = filterParams(gf.params)
        params.append(RecipeParamSpec.color("fg", "Foreground", .black).asAdvanced())
        params.append(RecipeParamSpec.color("bg", "Background", .white).asAdvanced())
        return RecipeNodeSpec(type: "gallery." + gf.rawValue, name: gf.displayName, category: .filter, group: "Gallery · " + gf.category,
                              inputs: [image], params: params, keywords: ["filter gallery", "artistic", gf.category.lowercased()], bypass: "Image") { ev in
            let img = try ev.need()
            var values: [String: Double] = [:]
            for p in gf.params { values[p.key] = ev.num(p.key) }
            ev.set(gf.apply(img, values: values, fg: ev.color("fg"), bg: ev.color("bg"), canvas: ev.canvas).cropped(to: ev.canvas))
        }
    }
}
