import AppKit
import CoreGraphics
import ImageCratCore

// SVG import, part 6: the element tree → Lumen layers.
//
// Every drawable becomes the most editable layer that renders the same: shapes → shape layers (live rectangle /
// ellipse parameters where possible), text → text layers, groups → groups, clip paths → vector masks, masks → layer
// masks, images → pixel layers or smart objects. What Lumen cannot represent is handed to the rasterizer as a job for
// just that element (`SVGImportRaster`), and every such decision is written to the report.

struct SVGImportRasterJob {
    enum Kind {
        /// The element with everything it draws.
        case element
        /// Coverage of mask `id` as applied to an element whose bounding box is `bbox` in its user space, and whose own
        /// transform is `local`.
        case mask(id: String, bbox: CGRect, local: CGAffineTransform)
    }
    var layerID: UUID
    var node: SVGImportNode
    var kind: Kind
    var what: String
    /// Element jobs: the element's own clip path, mask and filter are part of the pixels (opacity and blending never are).
    var baked = true
}

final class SVGImportBuilder {
    struct Context {
        var ctm: CGAffineTransform
        var style = SVGImportStyle()
        /// Nearest viewport in user units (percentage lengths).
        var viewport: CGSize
        var depth = 0
        /// Elements currently being instantiated through `<use>` (cycle guard).
        var uses: [ObjectIdentifier] = []
        var hidden = false
    }

    let doc: SVGImportDocument
    let settings: SVGImportSettings
    var report = SVGImportReport()
    let width: Int, height: Int
    let natural: CGSize
    let rootTransform: CGAffineTransform
    var jobs: [SVGImportRasterJob] = []
    /// Layers whose name came from the file (not a kind name).
    var named: Set<UUID> = []
    /// Elements (counting every `<use>` instance) the importer will build before giving up on the rest.
    static let elementBudget = 120_000
    private var budget = SVGImportBuilder.elementBudget
    private var truncated = false
    /// Set by `finish` when the built layers cannot express the element after all (it is then rasterized).
    private var rasterInstead: String? = nil
    /// Referenced elements that are not there (reported once each).
    private var missing: Set<String> = []

    var canvas: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    init(doc: SVGImportDocument, settings: SVGImportSettings, size: (Int, Int), natural: CGSize) {
        self.doc = doc; self.settings = settings
        width = size.0; height = size.1
        self.natural = natural
        let vp = CGRect(origin: .zero, size: natural)
        var t = CGAffineTransform.identity
        if let vb = SVGImportGeometry.viewBox(doc.root) { t = SVGImportGeometry.viewBoxTransform(vb, doc.root.attrs["preserveAspectRatio"], viewport: vp) }
        rootTransform = t.concatenating(SVGImport.fit(natural, size))
    }

    // MARK: Root

    /// `build()` with enough stack for deeply nested files: the walk recurses per nesting level, and threads other
    /// than the main one only get 512 KB.
    func buildWithRoomToRecurse() -> [Layer] {
        if Thread.isMainThread { return build() }
        var out: [Layer] = []
        let done = DispatchSemaphore(value: 0)
        let t = Thread { out = self.build(); done.signal() }
        t.stackSize = 16 << 20
        t.start()
        done.wait()
        return out
    }

    func build() -> [Layer] {
        let root = doc.root
        let vb = SVGImportGeometry.viewBox(root)
        var ctx = Context(ctm: rootTransform, viewport: vb?.size ?? natural)
        ctx.style.apply(root, viewport: ctx.viewport)
        if let w = doc.parseWarning { report.note(.warning, w) }
        var stack = [root]
        var animated = false, scripted = false
        while let x = stack.popLast() {
            if x.isSVG, Self.animation.contains(x.tag) { animated = true }
            if x.isSVG, x.tag == "script" { scripted = true }
            stack.append(contentsOf: x.children)
        }
        if animated { report.note(.ignored, "Animation (the static artwork was imported)") }
        if scripted { report.note(.ignored, "Script") }
        for n in doc.cssNotes.sorted() { report.note(.ignored, "Style sheet: \(n)") }
        var layers: [Layer]
        // opacity / clip / mask / filter on the root element apply to everything
        func has(_ k: String) -> Bool { ctx.style.own(root, k).map { $0.lowercased() != "none" } ?? false }
        if has("mask") || has("filter") {
            var l = hiddenOrJob(root, ctx, name: "Artwork", what: has("mask") ? "mask on the whole image" : "filter on the whole image")!
            applyOpacityAndBlend(root, ctx, &l, isGroup: false)
            layers = [l]
        } else {
            layers = children(root, ctx)
            if has("opacity") || has("clip-path") {
                var g = Layer(name: "Artwork", content: .group(GroupContent(children: layers)))
                if let done = finish(root, ctx, &g, isGroup: true) { layers = simplified(done, named: false) } else { layers = [] }
            }
        }
        if truncated { report.note(.warning, "The file is too complex to import completely; some elements were left out.") }
        return layers
    }

    // MARK: Elements

    /// Elements that never draw by themselves.
    private static let silent: Set<String> = [
        "defs", "style", "title", "desc", "metadata", "clipPath", "mask", "pattern", "marker", "linearGradient", "radialGradient", "filter", "symbol",
        "font", "font-face", "cursor", "view", "stop", "color-profile", "solidcolor", "meshgradient", "hatch", "glyph", "missing-glyph",
    ]
    private static let animation: Set<String> = ["animate", "animateTransform", "animateMotion", "animateColor", "set", "mpath", "discard"]
    private static let shapes: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]

    func children(_ n: SVGImportNode, _ ctx: Context) -> [Layer] {
        var out: [Layer] = []
        for c in n.children where !c.isText { out += element(c, ctx) }
        return out
    }

    func element(_ n: SVGImportNode, _ parent: Context) -> [Layer] {
        guard n.isSVG, !n.isText else { return [] }
        if Self.silent.contains(n.tag) { return [] }
        if Self.animation.contains(n.tag) || n.tag == "script" { return [] }
        budget -= 1
        guard budget >= 0, parent.depth < 96 else { truncated = true; return [] }
        var ctx = parent
        ctx.depth += 1
        ctx.style.apply(n, viewport: parent.viewport)
        var hidden = false
        if ctx.style.own(n, "display")?.lowercased() == "none" {
            guard settings.includeHidden, !parent.hidden else { return [] }
            hidden = true
            ctx.hidden = true
        }
        guard let local = localTransform(n, ctx) else { return [] }
        ctx.ctm = local.concatenating(parent.ctm)
        guard ctx.ctm.isFinite, abs(ctx.ctm.determinant) > 1e-18 else { return [] }
        let jobsBefore = jobs.count
        let reportBefore = report

        // whatever Lumen has no equivalent for is rasterized as a unit
        if let reason = rasterReason(n, ctx) {
            let (name, isNamed) = SVGImportNames.name(n, fallback: defaultName(n))
            guard var l = hiddenOrJob(n, ctx, name: name, what: reason) else { return [] }
            if isNamed { named.insert(l.id) }
            applyOpacityAndBlend(n, ctx, &l, isGroup: false)
            if hidden { l.isVisible = false }
            return [l]
        }

        var produced: [Layer]
        var isGroup = false
        switch n.tag {
        case "g", "a":
            produced = children(n, ctx); isGroup = true
        case "svg":
            produced = nestedSVG(n, &ctx, parent: parent); isGroup = true
        case "switch":
            produced = switchChild(n).map { element($0, ctx) } ?? []; isGroup = true
        case "use":
            produced = use(n, ctx); isGroup = true
        case "text":
            produced = text(n, ctx)
        case "image":
            produced = image(n, ctx)
        case _ where Self.shapes.contains(n.tag):
            produced = shape(n, ctx)
        default:
            report.note(.ignored, "Unknown element <\(n.tag)>")
            return []
        }
        if produced.isEmpty { return [] }

        let (name, isNamed) = SVGImportNames.name(n, fallback: isGroup ? "Group" : (produced.count == 1 ? produced[0].name : defaultName(n)))
        var layer: Layer
        let leaf = !isGroup
        if !isGroup && produced.count == 1 {
            layer = produced[0]
            // a text layer keeps its text as the name unless the file names the element
            if isNamed || !layer.isText { layer.name = name }
        } else {
            var g = GroupContent(children: produced)
            g.isExpanded = ctx.depth <= 2
            layer = Layer(name: name, content: .group(g))
            isGroup = true
            report.groups += 1
        }
        if isNamed { named.insert(layer.id) }
        rasterInstead = nil
        guard var done = finish(n, ctx, &layer, isGroup: isGroup) else {
            guard let why = rasterInstead else { return [] }
            // the layers just built are dropped, with the jobs they asked for
            rasterInstead = nil
            jobs.removeSubrange(jobsBefore...)
            report = reportBefore
            guard var l = hiddenOrJob(n, ctx, name: name, what: why) else { return [] }
            if isNamed { named.insert(l.id) }
            applyOpacityAndBlend(n, ctx, &l, isGroup: false)
            if hidden { l.isVisible = false }
            return [l]
        }
        if hidden { done.isVisible = false; report.hidden += 1 }
        // the parts of one element (fill + separated stroke, lines of a text) stay together as its group
        return done.isGroup && !leaf ? simplified(done, named: isNamed) : [done]
    }

    private func defaultName(_ n: SVGImportNode) -> String {
        switch n.tag {
        case "g", "a", "svg", "use", "switch": return "Group"
        case "text": return "Text"
        case "image": return "Image"
        case "foreignObject": return "Embedded Content"
        case "rect": return "Rectangle"
        case "circle", "ellipse": return "Ellipse"
        case "line": return "Line"
        case "polygon": return "Polygon"
        case "polyline": return "Polyline"
        default: return "Path"
        }
    }

    /// The element's own transform (attribute, overridden by the CSS property), about its transform origin.
    /// nil = the element cannot be drawn (a singular matrix).
    func localTransform(_ n: SVGImportNode, _ ctx: Context) -> CGAffineTransform? {
        var t = CGAffineTransform.identity
        if let css = ctx.style.own(n, "transform") {
            if css.lowercased() != "none" { t = SVGImportValue.transform(css) ?? SVGImportValue.transform(n.attrs["transform"]) ?? .identity }
        } else if let a = n.attrs["transform"] {
            guard let parsed = SVGImportValue.transform(a) else { return .identity }     // an invalid list is ignored
            t = parsed
        }
        if !t.isIdentity, let o = ctx.style.own(n, "transform-origin") {
            let fillBox = ctx.style.own(n, "transform-box")?.lowercased() == "fill-box"
            var box = CGRect(origin: .zero, size: ctx.viewport)
            if fillBox, let b = objectBBox(n, ctx) { box = b }
            let parts = o.lowercased().split(separator: " ").map(String.init)
            func comp(_ s: String, _ size: CGFloat, _ origin: CGFloat, horizontal: Bool) -> CGFloat? {
                switch s {
                case "center": return origin + size / 2
                case "left": return horizontal ? origin : nil
                case "right": return horizontal ? origin + size : nil
                case "top": return horizontal ? nil : origin
                case "bottom": return horizontal ? nil : origin + size
                default:
                    guard let l = SVGImportValue.length(s) else { return nil }
                    return (l.unit == .percent ? origin : (fillBox ? origin : 0)) + CGFloat(l.resolve(percentOf: Double(size), fontSize: ctx.style.fontSize))
                }
            }
            var ox: CGFloat? = nil, oy: CGFloat? = nil
            if parts.count >= 2 {
                ox = comp(parts[0], box.width, box.minX, horizontal: true); oy = comp(parts[1], box.height, box.minY, horizontal: false)
                if ox == nil || oy == nil {     // "top left" order
                    ox = comp(parts[1], box.width, box.minX, horizontal: true); oy = comp(parts[0], box.height, box.minY, horizontal: false)
                }
            } else if parts.count == 1 {
                ox = comp(parts[0], box.width, box.minX, horizontal: true) ?? box.midX
                oy = ["top", "bottom"].contains(parts[0]) ? comp(parts[0], box.height, box.minY, horizontal: false) : box.midY
            }
            if let x = ox, let y = oy, x != 0 || y != 0 {
                t = CGAffineTransform(translationX: -x, y: -y).concatenating(t).concatenating(CGAffineTransform(translationX: x, y: y))
            }
        }
        return t.isFinite ? t : nil
    }

    // MARK: Containers

    private func nestedSVG(_ n: SVGImportNode, _ ctx: inout Context, parent: Context) -> [Layer] {
        let em = ctx.style.fontSize
        func len(_ name: String, _ ref: CGFloat, _ def: CGFloat) -> CGFloat {
            SVGImportValue.length(n.attrs[name]).map { CGFloat($0.resolve(percentOf: Double(ref), fontSize: em)) } ?? def
        }
        let port = CGRect(x: len("x", parent.viewport.width, 0), y: len("y", parent.viewport.height, 0),
                          width: len("width", parent.viewport.width, parent.viewport.width), height: len("height", parent.viewport.height, parent.viewport.height))
        guard port.width > 0, port.height > 0 else { return [] }
        return viewportContent(n, contentOf: n, port: port, &ctx)
    }

    /// Children of `content` (an `<svg>` or `<symbol>`) drawn into viewport `port` of the current user space; the
    /// viewport clips unless overflow is visible.
    private func viewportContent(_ owner: SVGImportNode, contentOf content: SVGImportNode, port: CGRect, _ ctx: inout Context) -> [Layer] {
        let outer = ctx.ctm
        var inner = CGAffineTransform(translationX: port.minX, y: port.minY)
        if let vb = SVGImportGeometry.viewBox(content) {
            inner = SVGImportGeometry.viewBoxTransform(vb, content.attrs["preserveAspectRatio"], viewport: port)
            ctx.viewport = vb.size
        } else {
            ctx.viewport = port.size
        }
        ctx.ctm = inner.concatenating(outer)
        var layers = children(content, ctx)
        let overflow = (ctx.style.own(content, "overflow") ?? "hidden").lowercased()
        if overflow != "visible" && overflow != "auto", !layers.isEmpty, let clip = SVGImportGeometry.docPath(CGPath(rect: port, transform: nil), outer) {
            // only when it actually cuts something off
            if !coversCanvas(clip) {
                var g = Layer(name: "Viewport", content: .group(GroupContent(children: layers)))
                g.vectorMask = VectorPath.from(cgPath: clip)
                layers = simplified(g, named: false)
            }
        }
        return layers
    }

    private func switchChild(_ n: SVGImportNode) -> SVGImportNode? {
        let langs = Locale.preferredLanguages.map { $0.lowercased() } + ["en"]
        for c in n.elements where c.isSVG {
            if let ext = c.attrs["requiredExtensions"], !ext.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let sl = c.attrs["systemLanguage"] {
                let want = sl.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard want.contains(where: { w in langs.contains { $0 == w || $0.hasPrefix(w + "-") } }) else { continue }
            }
            return c
        }
        return nil
    }

    private func use(_ n: SVGImportNode, _ ctx: Context) -> [Layer] {
        guard let target = doc.target(n.href) else {
            if let h = n.href, !h.hasPrefix("#"), missing.insert(h).inserted { report.note(.ignored, "Reference to another file (“\(h.prefix(60))”) was not loaded") }
            return []
        }
        // a reference to an ancestor (or to something already being instantiated) would never end
        var a: SVGImportNode? = n
        while let x = a { if x === target { return [] }; a = x.parent }
        let key = ObjectIdentifier(target)
        guard !ctx.uses.contains(key), ctx.uses.count < 24 else { return [] }
        var c = ctx
        c.uses.append(key)
        let em = ctx.style.fontSize
        func len(_ name: String, _ ref: CGFloat) -> CGFloat? {
            SVGImportValue.length(n.attrs[name]).map { CGFloat($0.resolve(percentOf: Double(ref), fontSize: em)) }
        }
        let x = len("x", ctx.viewport.width) ?? 0, y = len("y", ctx.viewport.height) ?? 0
        let before = jobs.count
        let reportBefore = report
        var layers: [Layer]
        if target.tag == "symbol" || target.tag == "svg" {
            // the referenced viewport element is sized by the <use> (or by its own width / height)
            var t = c
            t.depth += 1
            t.style.apply(target, viewport: ctx.viewport)
            func own(_ name: String, _ ref: CGFloat) -> CGFloat? {
                SVGImportValue.length(target.attrs[name]).map { CGFloat($0.resolve(percentOf: Double(ref), fontSize: em)) }
            }
            let w = len("width", ctx.viewport.width) ?? own("width", ctx.viewport.width) ?? ctx.viewport.width
            let h = len("height", ctx.viewport.height) ?? own("height", ctx.viewport.height) ?? ctx.viewport.height
            guard w > 0, h > 0 else { return [] }
            if ctx.style.own(target, "display")?.lowercased() == "none", target.tag == "svg" { return [] }
            let explicit = n.attrs["width"] != nil || target.attrs["width"] != nil || target.attrs["viewBox"] != nil
            var port = CGRect(x: x, y: y, width: w, height: h)
            if !explicit { port = CGRect(x: x, y: y, width: 1e7, height: 1e7) }      // no size anywhere: nothing to clip against
            layers = viewportContent(target, contentOf: target, port: port, &t)
        } else {
            c.ctm = CGAffineTransform(translationX: x, y: y).concatenating(ctx.ctm)
            layers = element(target, c)
        }
        // something inside needs pixels: the instance is rasterized as one piece, since a job is addressed by its place
        // in the document and referenced content has none
        if jobs.count > before {
            let whats = Set(jobs[before...].map(\.what)).sorted().joined(separator: ", ")
            jobs.removeSubrange(before...)
            report = reportBefore
            guard let l = hiddenOrJob(n, ctx, name: SVGImportNames.name(n, fallback: SVGImportNames.name(target, fallback: "Symbol").0).0, what: whats, baked: false) else { return [] }
            return [l]
        }
        if layers.count == 1, !named.contains(layers[0].id), case (let nm, true) = SVGImportNames.name(target, fallback: "") {
            layers[0].name = nm; named.insert(layers[0].id)
        }
        return layers
    }

    // MARK: Finishing (opacity, blending, clip, mask, filter)

    private static let blendModes: [String: BlendMode] = [
        "normal": .normal, "multiply": .multiply, "screen": .screen, "overlay": .overlay, "darken": .darken, "lighten": .lighten,
        "color-dodge": .colorDodge, "color-burn": .colorBurn, "hard-light": .hardLight, "soft-light": .softLight, "difference": .difference,
        "exclusion": .exclusion, "hue": .hue, "saturation": .saturation, "color": .color, "luminosity": .luminosity, "plus-lighter": .linearDodge, "plus-darker": .linearBurn,
    ]

    private func applyOpacityAndBlend(_ n: SVGImportNode, _ ctx: Context, _ l: inout Layer, isGroup: Bool) {
        let o = ctx.style.own(n, "opacity").flatMap { SVGImportValue.number($0) }.map { clamp($0, 0, 1) } ?? 1
        l.opacity = o
        let m = ctx.style.own(n, "mix-blend-mode")?.lowercased() ?? "normal"
        if m != "normal", let mode = Self.blendModes[m] {
            l.blendMode = mode
            report.blendModes += 1
            return
        }
        if m != "normal" { report.note(.ignored, "Blend mode “\(m)” (normal was used)") }
        // a group is isolated by opacity or `isolation`; otherwise its children blend with what is below the group
        if isGroup { l.blendMode = o < 0.9999 || ctx.style.own(n, "isolation")?.lowercased() == "isolate" ? .normal : .passThrough }
    }

    /// Applies the element's group-level properties to its layer. nil = the element draws nothing.
    private func finish(_ n: SVGImportNode, _ ctx: Context, _ l: inout Layer, isGroup: Bool) -> Layer? {
        applyOpacityAndBlend(n, ctx, &l, isGroup: isGroup)
        var isolate = false
        if let ref = ctx.style.own(n, "clip-path"), ref.lowercased() != "none", let cp = doc.target(ref), cp.tag == "clipPath" {
            let bbox = objectBBox(n, ctx)
            guard let path = clipPath(cp, ctx: ctx, bbox: bbox, depth: 0), !path.isEmpty, !path.boundingBoxOfPath.isNull else { return nil }
            if !coversCanvas(path) {
                intersectVectorMask(&l, path)
                isolate = true
                report.clips += 1
            }
        }
        if let ref = ctx.style.own(n, "mask"), ref.lowercased() != "none", let m = doc.target(ref), m.tag == "mask", let id = m.id {
            let bbox = objectBBox(n, ctx)
            if let path = maskAsClip(m, ctx: ctx, bbox: bbox) {
                // a mask that is just opaque shapes is a clip: keep it as an editable vector mask
                guard !path.isEmpty, !path.boundingBoxOfPath.isNull else { return nil }
                if !coversCanvas(path) {
                    intersectVectorMask(&l, path)
                    isolate = true
                    report.vectorMasks += 1
                }
            } else if ctx.hidden {
                report.note(.ignored, "Mask on a hidden element")
            } else {
                let local = localTransform(n, ctx) ?? .identity
                jobs.append(SVGImportRasterJob(layerID: l.id, node: n, kind: .mask(id: id, bbox: bbox ?? .zero, local: local), what: "mask"))
                isolate = true
                report.masks += 1
            }
        }
        if let f = ctx.style.own(n, "filter"), f.lowercased() != "none", let shadows = SVGImportFilters.shadows(f, doc: doc, ctx: ctx, bbox: nil) {
            // SVG builds a knocked-out drop shadow and an inner shadow from the artwork's hard silhouette; the layer
            // effects use its actual alpha. They agree when the artwork is opaque — or uniformly translucent, which
            // becomes fill opacity (effects ignore it).
            if shadows.drop.contains(where: \.layerKnocksOut) || !shadows.inner.isEmpty, !opaque(l) {
                guard let a = uniformAlpha(l), a > 0 else {
                    rasterInstead = "shadow filter on translucent artwork"
                    return nil
                }
                makeOpaque(&l)
                l.fillOpacity = a
            }
            // the primary effect is drawn on top of the extra ones
            var fx = l.effects
            for (i, s) in shadows.drop.reversed().enumerated() {
                if i == 0 { fx.dropShadow = s } else { fx.extraDropShadows.append(s) }
            }
            for (i, s) in shadows.inner.reversed().enumerated() {
                if i == 0 { fx.innerShadow = s } else { fx.extraInnerShadows.append(s) }
            }
            l.effects = fx
            // SVG filters the element before it is clipped and masked
            if l.vectorMask != nil { l.vectorMaskHidesEffects = true }
            if jobs.last?.layerID == l.id { l.layerMaskHidesEffects = true }
            isolate = true
            report.effects += 1
        }
        if isGroup, isolate, l.blendMode == .passThrough { l.blendMode = .normal }
        return l
    }

    /// Whether everything the layer draws is fully opaque (antialiased edges aside).
    private func opaque(_ l: Layer) -> Bool {
        func solid(_ p: PaintStyle) -> Bool {
            switch p {
            case .none: return true
            case .color(let c): return c.a >= 0.999
            case .gradient(let g): return g.gradient.stops.allSatisfy { $0.color.a >= 0.999 }
            case .pattern: return false
            }
        }
        if l.mask != nil || jobs.contains(where: { $0.layerID == l.id }) { return false }
        switch l.content {
        case .shape(let s): return solid(s.fill) && solid(s.stroke.paint)
        case .text(let t): return t.color.a >= 0.999 && t.runs.allSatisfy { ($0.style.color?.a ?? 1) >= 0.999 }
        case .group(let g): return g.children.allSatisfy { !$0.isVisible || ($0.opacity >= 0.999 && opaque($0)) }
        default: return false
        }
    }

    /// The single alpha the layer's artwork is drawn with (one plain shape, possibly inside single-child groups).
    private func uniformAlpha(_ l: Layer) -> Double? {
        if l.mask != nil || l.effects.hasAny || jobs.contains(where: { $0.layerID == l.id }) { return nil }
        switch l.content {
        case .shape(let s):
            guard case .color(let c) = s.fill, s.stroke.paint.isNone else { return nil }
            return c.a
        case .group(let g):
            let visible = g.children.filter(\.isVisible)
            guard visible.count == 1, g.children.count == 1, visible[0].blendMode == .normal || visible[0].blendMode == .passThrough,
                  let a = uniformAlpha(visible[0]) else { return nil }
            return a * visible[0].opacity
        default: return nil
        }
    }

    /// Removes the alpha `uniformAlpha` found (it moves to the fill opacity of the layer that carries the effects).
    private func makeOpaque(_ l: inout Layer) {
        switch l.content {
        case .shape(var s):
            if case .color(let c) = s.fill { s.fill = .color(c.withAlpha(1)); l.content = .shape(s) }
        case .group(var g):
            for i in g.children.indices { g.children[i].opacity = 1; makeOpaque(&g.children[i]) }
            l.content = .group(g)
        default: break
        }
    }

    func intersectVectorMask(_ l: inout Layer, _ path: CGPath) {
        if let old = l.vectorMask, !old.isEmpty {
            let both = old.resolved.path.intersection(path, using: .winding)
            l.vectorMask = VectorPath.from(cgPath: both)
        } else {
            l.vectorMask = VectorPath.from(cgPath: path)
        }
    }

    /// A clip that contains the whole canvas clips nothing.
    func coversCanvas(_ path: CGPath) -> Bool {
        var r = CGRect.zero
        guard path.isRect(&r) else { return false }
        return r.insetBy(dx: -0.25, dy: -0.25).contains(canvas)
    }

    /// Clip region of a `<clipPath>` in document space (nil: nothing usable).
    func clipPath(_ cp: SVGImportNode, ctx: Context, bbox: CGRect?, depth: Int) -> CGPath? {
        guard depth < 8 else { return nil }
        var base = ctx.ctm
        if (cp.attrs["clipPathUnits"] ?? "userSpaceOnUse") == "objectBoundingBox" {
            guard let b = bbox, b.width > 0, b.height > 0 else { return CGMutablePath() }
            base = CGAffineTransform(a: b.width, b: 0, c: 0, d: b.height, tx: b.minX, ty: b.minY).concatenating(base)
        }
        if let t = SVGImportValue.transform(cp.decls["transform"] ?? cp.attrs["transform"]) { base = t.concatenating(base) }
        var cstyle = SVGImportStyle()
        // the clip path's children inherit from the clipPath element and its ancestors, not from the clipped element
        var chain: [SVGImportNode] = []
        var a: SVGImportNode? = cp
        while let x = a { chain.append(x); a = x.parent }
        for x in chain.reversed() { cstyle.apply(x, viewport: ctx.viewport) }
        var acc: CGPath? = nil
        var count = 0
        func add(_ child: SVGImportNode, _ style: SVGImportStyle, _ t: CGAffineTransform, _ level: Int) {
            guard child.isSVG, !child.isText, count < 4000, level < 6 else { return }
            var st = style
            st.apply(child, viewport: ctx.viewport)
            if st.own(child, "display")?.lowercased() == "none" || !st.visible { return }
            var cctx = ctx
            cctx.style = st
            guard let local = localTransform(child, cctx) else { return }
            let m = local.concatenating(t)
            var user: CGPath? = nil
            if Self.shapes.contains(child.tag) {
                user = SVGImportGeometry.shape(child, style: st, viewport: ctx.viewport)?.path
            } else if child.tag == "text" {
                cctx.ctm = .identity
                user = textOutline(child, cctx)
            } else if child.tag == "use", let target = doc.target(child.href), target !== cp {
                let em = st.fontSize
                let x = SVGImportValue.length(child.attrs["x"])?.resolve(percentOf: Double(ctx.viewport.width), fontSize: em) ?? 0
                let y = SVGImportValue.length(child.attrs["y"])?.resolve(percentOf: Double(ctx.viewport.height), fontSize: em) ?? 0
                add(target, st, CGAffineTransform(translationX: x, y: y).concatenating(m), level + 1)
                return
            } else if child.tag == "g" && level > 0 {
                // only reachable through <use>; a <g> directly inside clipPath is not allowed and clips nothing
                for c in child.children { add(c, st, m, level + 1) }
                return
            }
            guard var p = user, !p.isEmpty else { return }
            count += 1
            if st.clipEvenOdd { p = p.normalized(using: .evenOdd) }
            guard var placed = SVGImportGeometry.docPath(p, m) else { return }
            if let ref = st.own(child, "clip-path"), let inner = doc.target(ref), inner.tag == "clipPath", inner !== cp {
                var ic = ctx
                ic.ctm = m
                if let ip = clipPath(inner, ctx: ic, bbox: p.boundingBoxOfPath, depth: depth + 1) { placed = placed.intersection(ip, using: .winding) }
            }
            acc = acc.map { $0.union(placed, using: .winding) } ?? placed.normalized(using: .winding)
        }
        for c in cp.children { add(c, cstyle, base, 0) }
        guard var out = acc else { return CGMutablePath() }
        if let ref = cstyle.own(cp, "clip-path"), let outer = doc.target(ref), outer.tag == "clipPath", outer !== cp,
           let op = clipPath(outer, ctx: ctx, bbox: bbox, depth: depth + 1) {
            out = out.intersection(op, using: .winding)
        }
        return out
    }

    /// The region a `<mask>` reveals, when the mask is nothing but fully opaque (luminance masks: white) shapes — then
    /// it clips exactly like a clip path. nil when the mask has soft or partial coverage and needs pixels.
    func maskAsClip(_ mask: SVGImportNode, ctx: Context, bbox: CGRect?) -> CGPath? {
        let alphaType = (mask.decls["mask-type"] ?? "luminance").lowercased() == "alpha"
        var base = ctx.ctm
        if (mask.attrs["maskContentUnits"] ?? "userSpaceOnUse") == "objectBoundingBox" {
            guard let b = bbox, b.width > 0, b.height > 0 else { return CGMutablePath() }
            base = CGAffineTransform(a: b.width, b: 0, c: 0, d: b.height, tx: b.minX, ty: b.minY).concatenating(base)
        }
        var mstyle = SVGImportStyle()
        var chain: [SVGImportNode] = []
        var a: SVGImportNode? = mask
        while let x = a { chain.append(x); a = x.parent }
        for x in chain.reversed() { mstyle.apply(x, viewport: ctx.viewport) }
        var acc: CGPath? = nil
        var count = 0
        var soft = false
        func add(_ child: SVGImportNode, _ style: SVGImportStyle, _ t: CGAffineTransform, _ level: Int) {
            guard !soft, child.isSVG, !child.isText, !Self.silent.contains(child.tag) else { return }
            guard count < 2000, level < 8 else { soft = true; return }
            var st = style
            st.apply(child, viewport: ctx.viewport)
            if st.own(child, "display")?.lowercased() == "none" { return }
            for k in ["filter", "mask", "clip-path"] { if let v = st.own(child, k), v.lowercased() != "none" { soft = true; return } }
            if let o = st.own(child, "opacity").flatMap({ SVGImportValue.number($0) }), o < 0.999 { soft = true; return }
            var cctx = ctx
            cctx.style = st
            guard let local = localTransform(child, cctx) else { return }
            let m = local.concatenating(t)
            if child.tag == "g" || child.tag == "a" {
                for c in child.children { add(c, st, m, level + 1) }
                return
            }
            if child.tag == "use", let target = doc.target(child.href), target !== mask, target.tag != "symbol", target.tag != "svg" {
                let em = st.fontSize
                let x = SVGImportValue.length(child.attrs["x"])?.resolve(percentOf: Double(ctx.viewport.width), fontSize: em) ?? 0
                let y = SVGImportValue.length(child.attrs["y"])?.resolve(percentOf: Double(ctx.viewport.height), fontSize: em) ?? 0
                add(target, st, CGAffineTransform(translationX: x, y: y).concatenating(m), level + 1)
                return
            }
            guard Self.shapes.contains(child.tag) else { soft = true; return }
            guard st.visible else { return }
            guard let geo = SVGImportGeometry.shape(child, style: st, viewport: ctx.viewport) else { return }
            // the paint must cover fully: an opaque colour (white for luminance masks), no stroke
            if st.stroke != .none && st.strokeWidth > 0 && st.strokeOpacity > 0 { soft = true; return }
            var color: RGBA
            switch st.fill {
            case .color(let c): color = c
            case .currentColor: color = st.color
            case .none: return
            case .server: soft = true; return
            }
            guard color.a * st.fillOpacity >= 0.999 else { soft = true; return }
            if !alphaType && min(color.r, color.g, color.b) < 0.995 { soft = true; return }
            var p = geo.path
            if st.evenOdd { p = p.normalized(using: .evenOdd) }
            guard let placed = SVGImportGeometry.docPath(p, m) else { return }
            count += 1
            acc = acc.map { $0.union(placed, using: .winding) } ?? placed.normalized(using: .winding)
        }
        for c in mask.children { add(c, mstyle, base, 0) }
        if soft { return nil }
        guard var out = acc else { return CGMutablePath() }
        // the mask region
        let objUnits = (mask.attrs["maskUnits"] ?? "objectBoundingBox") != "userSpaceOnUse"
        var region: CGRect
        func frac(_ name: String, _ def: Double) -> Double { SVGImportValue.number(mask.attrs[name]) ?? def }
        if objUnits {
            guard let b = bbox, b.width > 0, b.height > 0 else { return CGMutablePath() }
            region = CGRect(x: b.minX + b.width * frac("x", -0.1), y: b.minY + b.height * frac("y", -0.1), width: b.width * frac("width", 1.2), height: b.height * frac("height", 1.2))
        } else {
            let em = ctx.style.fontSize
            func len(_ name: String, _ def: String, _ ref: CGFloat) -> CGFloat {
                CGFloat((SVGImportValue.length(mask.attrs[name]) ?? SVGImportValue.length(def)!).resolve(percentOf: Double(ref), fontSize: em))
            }
            region = CGRect(x: len("x", "-10%", ctx.viewport.width), y: len("y", "-10%", ctx.viewport.height),
                            width: len("width", "120%", ctx.viewport.width), height: len("height", "120%", ctx.viewport.height))
        }
        guard region.width > 0, region.height > 0, let rp = SVGImportGeometry.docPath(CGPath(rect: region, transform: nil), ctx.ctm) else { return CGMutablePath() }
        if !rp.boundingBoxOfPath.insetBy(dx: -0.01, dy: -0.01).contains(out.boundingBoxOfPath) || !ctx.ctm.isAxisAligned { out = out.intersection(rp, using: .winding) }
        return out
    }

    // MARK: What has to be rasterized

    /// A reason when the element (with its subtree) cannot be built from Lumen layers.
    func rasterReason(_ n: SVGImportNode, _ ctx: Context) -> String? {
        if n.tag == "foreignObject" { return "foreignObject (embedded HTML)" }
        let st = ctx.style
        if let f = st.own(n, "filter"), f.lowercased() != "none" {
            if SVGImportFilters.shadows(f, doc: doc, ctx: ctx, bbox: nil) == nil {
                if f.lowercased().hasPrefix("url("), doc.target(f) == nil { /* a filter that does not exist: the element is simply not filtered */ }
                else { return SVGImportFilters.describe(f, doc: doc) }
            }
        }
        if let c = st.own(n, "clip-path"), c.lowercased() != "none" {
            if !c.lowercased().hasPrefix("url(") { return "CSS clip-path shape" }
            if let cp = doc.target(c), cp.tag == "clipPath" {
                // images and masks inside a clip path, or a mask on it, cannot become a vector mask
                if cp.decls["mask"] != nil { return "masked clip path" }
            }
        }
        if let m = st.own(n, "mask"), m.lowercased() != "none", !m.lowercased().hasPrefix("url(") { return "CSS mask image" }
        if Self.shapes.contains(n.tag) {
            if case .server(let id, _) = st.stroke, doc.ids[id]?.tag == "pattern" { return "pattern stroke" }
            if case .server(let id, _) = st.fill, let s = doc.ids[id], s.tag == "pattern", imageFill(s) == nil { return "pattern fill" }
            if n.tag != "rect" && n.tag != "circle" && n.tag != "ellipse" {
                for id in [st.markerStart, st.markerMid, st.markerEnd] { if let id, doc.ids[id]?.tag == "marker" { return "markers" } }
            }
        }
        if n.tag == "text" { return textRasterReason(n, ctx) }
        return nil
    }

    /// Placeholder layer for a raster job (filled in by `SVGImportRaster`); nothing for hidden content.
    /// `baked`: the element's own clip / mask / filter are part of the pixels (false when `finish` still applies them).
    func hiddenOrJob(_ n: SVGImportNode, _ ctx: Context, name: String, what: String, baked: Bool = true) -> Layer? {
        if ctx.hidden { report.note(.ignored, "Hidden element that would have to be rasterized (\(what))"); return nil }
        let l = Layer.raster(name: name, buffer: PixelBuffer(width: 1, height: 1), origin: .zero)
        jobs.append(SVGImportRasterJob(layerID: l.id, node: n, kind: .element, what: what, baked: baked))
        return l
    }

    // MARK: Shapes

    func resolve(_ p: SVGImportPaint, opacity: Double, ctx: Context, bbox: CGRect, refBounds: CGRect) -> PaintStyle {
        switch p {
        case .none: return PaintStyle.none
        case .color(let c): return c.a * opacity <= 0 ? PaintStyle.none : .color(c.withAlpha(c.a * opacity))
        case .currentColor: return ctx.style.color.a * opacity <= 0 ? PaintStyle.none : .color(ctx.style.color.withAlpha(ctx.style.color.a * opacity))
        case .server(let id, let fallback):
            if let node = doc.ids[id], node.tag == "linearGradient" || node.tag == "radialGradient",
               let paint = SVGImportGradient.paint(node, doc: doc, style: ctx.style, viewport: ctx.viewport, opacity: opacity, bbox: bbox, ctm: ctx.ctm, refBounds: refBounds) {
                return paint
            }
            if doc.ids[id] == nil, missing.insert("#" + id).inserted { report.note(.ignored, "Paint “#\(id.prefix(40))” does not exist") }
            return fallback.map { resolve($0, opacity: opacity, ctx: ctx, bbox: bbox, refBounds: refBounds) } ?? PaintStyle.none
        }
    }

    /// A pattern that is a single image stretched over exactly one tile the size of the bounding box — how Figma and
    /// Sketch write an image fill. Returns the image element and its transform into bounding-box units.
    func imageFill(_ p: SVGImportNode) -> (image: SVGImportNode, toBox: CGAffineTransform)? {
        func unit(_ name: String, _ def: Double) -> Double { SVGImportValue.number(p.attrs[name]) ?? def }
        guard (p.attrs["patternUnits"] ?? "objectBoundingBox") == "objectBoundingBox", p.attrs["patternContentUnits"] == "objectBoundingBox",
              p.attrs["viewBox"] == nil, p.attrs["patternTransform"] == nil, p.href == nil,
              unit("x", 0) == 0, unit("y", 0) == 0, abs(unit("width", 0) - 1) < 1e-9, abs(unit("height", 0) - 1) < 1e-9 else { return nil }
        let kids = p.children.filter { $0.isSVG && !$0.isText && $0.tag != "title" && $0.tag != "desc" }
        guard kids.count == 1 else { return nil }
        var node = kids[0]
        var t = CGAffineTransform.identity
        var hops = 0
        while node.tag == "use", hops < 4, let target = doc.target(node.href) {
            for k in ["opacity", "filter", "mask", "clip-path"] where node.decls[k] != nil { return nil }
            let x = SVGImportValue.number(node.attrs["x"]) ?? 0, y = SVGImportValue.number(node.attrs["y"]) ?? 0
            t = CGAffineTransform(translationX: x, y: y).concatenating(SVGImportValue.transform(node.attrs["transform"]) ?? .identity).concatenating(t)
            node = target
            hops += 1
        }
        guard node.tag == "image", node.href != nil else { return nil }
        for k in ["opacity", "filter", "mask", "clip-path"] where node.decls[k] != nil { return nil }
        return (node, (SVGImportValue.transform(node.attrs["transform"]) ?? .identity).concatenating(t))
    }

    private func shape(_ n: SVGImportNode, _ ctx: Context) -> [Layer] {
        guard let geo = SVGImportGeometry.shape(n, style: ctx.style, viewport: ctx.viewport) else { return [] }
        if case .server(let id, _) = ctx.style.fill, let p = doc.ids[id], p.tag == "pattern", let fill = imageFill(p), ctx.style.visible {
            // image fill: the picture as its own layer (at its own resolution), cut out by the shape as a vector mask
            let b = geo.path.boundingBoxOfPath
            guard !b.isNull, b.width > 0, b.height > 0, let outline = SVGImportGeometry.docPath(geo.path, ctx.ctm) else { return [] }
            var ictx = ctx
            ictx.ctm = fill.toBox.concatenating(CGAffineTransform(a: b.width, b: 0, c: 0, d: b.height, tx: b.minX, ty: b.minY)).concatenating(ctx.ctm)
            ictx.style = SVGImportStyle()
            var layers = image(fill.image, ictx)
            for i in layers.indices {
                let clip = ctx.style.evenOdd ? outline.normalized(using: .evenOdd) : outline
                intersectVectorMask(&layers[i], clip)
                layers[i].opacity = ctx.style.fillOpacity
                layers[i].name = "Image Fill"
            }
            if !layers.isEmpty { report.note(.substituted, "Image fill (pattern holding one image) imported as an image layer with a vector mask") }
            let st = ctx.style
            guard st.stroke != .none, st.strokeWidth > 0, st.strokeOpacity > 0 else { return layers }
            var sctx = ctx
            sctx.style.fill = .none
            return layers + shapeLayers(geo, sctx, name: "Stroke")
        }
        var dashScale = 1.0
        if let pl = SVGImportValue.number(n.attrs["pathLength"]), pl > 0, !ctx.style.dash.isEmpty {
            let real = SVGImportValue.length(of: geo.path)
            if real > 0 { dashScale = real / pl }
        }
        let nonScaling = ctx.style.own(n, "vector-effect")?.lowercased() == "non-scaling-stroke"
        return shapeLayers(geo, ctx, name: geo.defaultName, dashScale: dashScale, nonScaling: nonScaling)
    }

    /// Shape layer(s) for an outline in user space painted with the context's fill and stroke.
    /// `bboxOverride`: the object bounding box when it is not the outline's own (text outlines).
    func shapeLayers(_ geo: SVGImportShape, _ ctx: Context, name: String, dashScale: Double = 1, nonScaling: Bool = false, bboxOverride: CGRect? = nil) -> [Layer] {
        let st = ctx.style
        guard st.visible else { return [] }
        let ctm = ctx.ctm
        guard let docPath = SVGImportGeometry.docPath(geo.path, ctm) else { return [] }
        let bbox = bboxOverride ?? geo.path.boundingBoxOfPath
        let refBounds = docPath.boundingBoxOfPath
        guard !bbox.isNull, !refBounds.isNull else { return [] }

        let hasStroke = st.stroke != .none && st.strokeWidth > 0 && st.strokeOpacity > 0
        let fill = resolve(st.fill, opacity: st.fillOpacity, ctx: ctx, bbox: bbox, refBounds: refBounds)
        var strokePaint = hasStroke ? resolve(st.stroke, opacity: st.strokeOpacity, ctx: ctx, bbox: bbox, refBounds: refBounds) : PaintStyle.none
        if fill.isNone && strokePaint.isNone { report.invisible += 1; return [] }

        // geometry: live rectangle / ellipse parameters when the transform allows, a path otherwise
        var content: ShapeContent
        let plainScale = ctm.isAxisAligned && ctm.a > 0 && ctm.d > 0
        // live parameters only for shapes of a sane size (`docPath` clamps enormous ones, and the clamped outline is used)
        let sane = max(abs(refBounds.minX), abs(refBounds.minY), abs(refBounds.maxX), abs(refBounds.maxY)) < 1_000_000
        switch sane ? geo.kind : .path {
        case .rect(let r, let radius) where plainScale && (radius <= 0 || abs(ctm.a - ctm.d) <= 1e-6 * abs(ctm.a)):
            content = ShapeContent(geometry: .rectangle(r.applying(ctm), cornerRadius: radius * Double(ctm.a)))
        case .rect(let r, let radius):
            content = ShapeContent(geometry: .rectangle(r, cornerRadius: radius), transform: ctm)
        case .ellipse(let r) where st.dash.isEmpty || strokePaint.isNone:
            content = plainScale ? ShapeContent(geometry: .ellipse(r.applying(ctm))) : ShapeContent(geometry: .ellipse(r), transform: ctm)
        default:
            var p = docPath
            if st.evenOdd && !fill.isNone { p = SVGImportGeometry.nonZeroEquivalent(ofEvenOdd: docPath) }
            content = ShapeContent(geometry: .path(VectorPath.from(cgPath: p)))
        }
        content.fill = fill
        content.stroke = StrokeStyle(paint: .none, width: 1)

        var layers: [Layer] = []
        var strokeLayer: Layer? = nil
        if !strokePaint.isNone {
            let scale = nonScaling ? 1 : Double(ctm.meanScale)
            let width = st.strokeWidth * scale
            let dash = st.dash.map { $0 * dashScale }
            var ss = StrokeStyle(paint: strokePaint, width: width, alignment: .center, cap: st.cap, join: st.join)
            if st.join == .miter { ss.miterLimit = st.miterLimit }
            if !dash.isEmpty {
                var d = dash.map { $0 / st.strokeWidth }
                if d.count % 2 == 1 { d += d }
                ss.dash = d
                // Core Graphics wants a phase inside the pattern (SVG allows any offset, negative too)
                let period = d.reduce(0, +)
                if st.dashOffset != 0, period > 0 {
                    var phase = (st.dashOffset * dashScale / st.strokeWidth).truncatingRemainder(dividingBy: period)
                    if phase < 0 { phase += period }
                    if phase > 1e-9 { ss.dashPhase = phase }
                }
            }
            // A stroke stays live when the pen is not distorted and Lumen strokes the same outline: the shape renderer
            // merges several closed subpaths before stroking, which only matters when they overlap or mix with open ones.
            let original = VectorPath.from(cgPath: docPath)
            var sameOutline = true
            if case .path(let vp) = content.geometry, vp != original { sameOutline = false }     // the fill needed a re-wound outline
            func strokeSafe(_ vp: VectorPath) -> Bool {
                (vp == original || sameOutline) && SVGImportGeometry.closedSubpathCount(vp) <= 1
                    || !SVGImportGeometry.strokesDiffer(docPath, vp.resolved.path, width: width, cap: st.cap, join: st.join, miter: st.miterLimit)
            }
            let penOK = nonScaling || ctm.isSimilarity
            // (a re-wound outline has the same contours; only where a dash pattern starts could differ)
            if penOK, !st.strokeFirst, sameOutline || dash.isEmpty, strokeSafe(content.path) {
                content.stroke = ss
            } else if penOK, strokeSafe(original) {
                var sc = ShapeContent(geometry: .path(original), fill: .none)
                sc.stroke = ss
                strokeLayer = Layer(name: fill.isNone ? name : "Stroke", content: .shape(sc))
                if !fill.isNone { report.note(.substituted, st.strokeFirst ? "Stroke painted under the fill (paint-order): fill and stroke became two shape layers"
                                              : "Even-odd fill with a stroke: fill and stroke became two shape layers") }
            } else {
                // outline the stroke in user space (that is where the pen is round) and place the result
                let outlineUser = SVGImportGeometry.strokeOutline(geo.path, width: nonScaling ? st.strokeWidth / max(1e-9, Double(ctm.meanScale)) : st.strokeWidth,
                                                                  cap: st.cap, join: st.join, miter: st.miterLimit, dash: dash, phase: st.dashOffset * dashScale)
                if let outline = SVGImportGeometry.docPath(outlineUser, ctm)?.normalized(using: .winding), !outline.isEmpty {
                    strokePaint = resolve(st.stroke, opacity: st.strokeOpacity, ctx: ctx, bbox: bbox, refBounds: outline.boundingBoxOfPath)
                    var sc = ShapeContent(geometry: .path(VectorPath.from(cgPath: outline)), fill: strokePaint)
                    sc.stroke = StrokeStyle(paint: .none, width: 1)
                    strokeLayer = Layer(name: fill.isNone ? name : "Stroke", content: .shape(sc))
                    report.note(.substituted, penOK ? "Stroke over overlapping subpaths converted to an outline shape" : "Stroke under a non-uniform scale or skew converted to an outline shape")
                }
            }
        }
        if !content.fill.isNone || !content.stroke.paint.isNone {
            layers.append(Layer(name: strokeLayer == nil ? name : "Fill", content: .shape(content)))
        }
        if let sl = strokeLayer { if st.strokeFirst { layers.insert(sl, at: 0) } else { layers.append(sl) } }
        if layers.count == 1 { layers[0].name = name }
        report.shapes += layers.count
        for l in layers {
            for p in [l.shape?.fill, l.shape?.stroke.paint] {
                if case .gradient(let g)? = p { report.gradients += 1; if g.shape != nil { report.shapedGradients += 1 } }
            }
        }
        return layers
    }

    // MARK: Images

    func image(_ n: SVGImportNode, _ ctx: Context) -> [Layer] {
        guard ctx.style.visible, let href = n.href, !href.isEmpty else { return [] }
        let em = ctx.style.fontSize
        func len(_ name: String, _ ref: CGFloat) -> CGFloat? {
            SVGImportValue.length(n.attrs[name] ?? n.decls[name]).map { CGFloat($0.resolve(percentOf: Double(ref), fontSize: em)) }
        }
        guard let loaded = SVGImportImages.load(href, doc: doc, depth: settings.nesting) else {
            report.note(.ignored, SVGImportImages.isRemote(href) ? "Linked image on the network (not downloaded)" : "Image that could not be loaded (“\(href.prefix(48))”)")
            return []
        }
        let size = loaded.size
        guard size.width > 0, size.height > 0 else { return [] }
        let x = len("x", ctx.viewport.width) ?? 0, y = len("y", ctx.viewport.height) ?? 0
        var w = len("width", ctx.viewport.width), h = len("height", ctx.viewport.height)
        if w == nil && h == nil { w = size.width; h = size.height }
        else if w == nil { w = h! * size.width / size.height }
        else if h == nil { h = w! * size.height / size.width }
        guard let bw = w, let bh = h, bw > 0, bh > 0 else { return [] }
        let box = CGRect(x: x, y: y, width: bw, height: bh)
        // the image is a viewBox of its pixel size fitted into the box
        let fit = SVGImportGeometry.viewBoxTransform(CGRect(origin: .zero, size: size), n.attrs["preserveAspectRatio"], viewport: box)
        let toDoc = fit.concatenating(ctx.ctm)
        let quad = Quad(rect: CGRect(origin: .zero, size: size)).applying(toDoc)
        guard quad.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 4_000_000 && abs($0.y) < 4_000_000 }) else { return [] }
        var layer: Layer
        switch loaded {
        case .pixels(let buf):
            let pixelExact = toDoc.isAxisAligned && abs(toDoc.a - 1) < 1e-6 && abs(toDoc.d - 1) < 1e-6
                && abs(toDoc.tx - toDoc.tx.rounded()) < 1e-6 && abs(toDoc.ty - toDoc.ty.rounded()) < 1e-6
            if pixelExact {
                layer = Layer.raster(name: "Image", buffer: buf, origin: IPoint(x: Int(toDoc.tx.rounded()), y: Int(toDoc.ty.rounded())))
                report.images += 1
            } else {
                // keeps the image's own pixels at any placement
                layer = Layer(name: "Image", content: .smartObject(SmartObjectContent(source: .image(buf), quad: quad, sourceName: "Image")))
                report.smartImages += 1
            }
        case .document(let st):
            layer = Layer(name: "Image", content: .smartObject(SmartObjectContent(source: .document(st), quad: quad, sourceName: "SVG Image")))
            report.smartImages += 1
        }
        // `slice` (and any fit that overflows the box) is clipped to the box
        let drawn = CGRect(origin: .zero, size: size).applying(fit)
        if !box.insetBy(dx: -0.01, dy: -0.01).contains(drawn), let clip = SVGImportGeometry.docPath(CGPath(rect: box, transform: nil), ctx.ctm) {
            layer.vectorMask = VectorPath.from(cgPath: clip)
        }
        return [layer]
    }

    // MARK: Bounding boxes

    /// Object bounding box of `n` in its own user space (the space its geometry attributes are in); nil when empty.
    func objectBBox(_ n: SVGImportNode, _ ctx: Context, depth: Int = 0) -> CGRect? {
        guard depth < 24 else { return nil }
        if Self.shapes.contains(n.tag) {
            let b = SVGImportGeometry.shape(n, style: ctx.style, viewport: ctx.viewport)?.path.boundingBoxOfPath
            return b.flatMap { $0.isNull ? nil : $0 }
        }
        let em = ctx.style.fontSize
        func len(_ node: SVGImportNode, _ name: String, _ ref: CGFloat) -> CGFloat? {
            SVGImportValue.length(node.attrs[name]).map { CGFloat($0.resolve(percentOf: Double(ref), fontSize: em)) }
        }
        switch n.tag {
        case "image":
            guard let w = len(n, "width", ctx.viewport.width), let h = len(n, "height", ctx.viewport.height) else { return nil }
            return CGRect(x: len(n, "x", ctx.viewport.width) ?? 0, y: len(n, "y", ctx.viewport.height) ?? 0, width: w, height: h)
        case "text":
            var c = ctx
            c.ctm = .identity
            let b = textOutline(n, c)?.boundingBoxOfPath
            return b.flatMap { $0.isNull ? nil : $0 }
        case "use":
            guard let target = doc.target(n.href), target !== n, !ctx.uses.contains(ObjectIdentifier(target)) else { return nil }
            var c = ctx
            c.uses.append(ObjectIdentifier(target))
            c.style.apply(target, viewport: ctx.viewport)
            guard let inner = objectBBox(target, c, depth: depth + 1) else { return nil }
            let t = (localTransform(target, c) ?? .identity).concatenating(CGAffineTransform(translationX: len(n, "x", ctx.viewport.width) ?? 0, y: len(n, "y", ctx.viewport.height) ?? 0))
            return inner.applying(t)
        case "g", "a", "svg", "switch", "symbol":
            var u: CGRect? = nil
            for child in n.children where child.isSVG && !child.isText && !Self.silent.contains(child.tag) {
                var c = ctx
                c.style.apply(child, viewport: ctx.viewport)
                if c.style.own(child, "display")?.lowercased() == "none" { continue }
                guard let b = objectBBox(child, c, depth: depth + 1), let t = localTransform(child, c) else { continue }
                let r = b.applying(t)
                u = u.map { $0.union(r) } ?? r
            }
            return u
        default:
            return nil
        }
    }

    // MARK: Simplifying the group tree

    private func plain(_ l: Layer) -> Bool {
        l.opacity >= 0.9999 && l.fillOpacity >= 0.9999 && l.blendMode == .passThrough && l.mask == nil && l.vectorMask == nil && !l.effects.hasAny && l.isVisible
            && !jobs.contains { $0.layerID == l.id }
    }

    /// Drops empty groups, dissolves anonymous groups that carry nothing, and folds a group into its only child when
    /// the group's properties can live on the child.
    func simplified(_ group: Layer, named isNamed: Bool) -> [Layer] {
        let kids = group.children
        if kids.isEmpty {
            jobs.removeAll { $0.layerID == group.id }
            return []
        }
        if plain(group) {
            if !isNamed { report.groups -= 1; return kids }
            if kids.count == 1, !named.contains(kids[0].id) {
                var c = kids[0]
                c.name = group.name
                named.insert(c.id)
                report.groups -= 1
                return [c]
            }
            return [group]
        }
        guard kids.count == 1 else { return [group] }
        var c = kids[0]
        // group properties move onto the single child when they mean the same thing there
        let childPlainBlend = c.blendMode == .normal || c.blendMode == .passThrough
        let groupBlendOK = group.blendMode == .normal || group.blendMode == .passThrough || childPlainBlend
        let groupJob = jobs.firstIndex { $0.layerID == group.id }
        let childBusy = c.mask != nil || jobs.contains { $0.layerID == c.id }
        // an isolating group must stay when its child blends with what is below it
        guard groupBlendOK, !(group.blendMode == .normal && !childPlainBlend), !group.effects.hasAny || (!c.effects.hasAny && !c.isGroup),
              groupJob == nil || !childBusy, !(isNamed && named.contains(c.id)) else { return [group] }
        c.opacity *= group.opacity
        c.fillOpacity *= group.fillOpacity
        if group.blendMode != .normal && group.blendMode != .passThrough { c.blendMode = group.blendMode }
        else if c.isGroup, group.blendMode == .normal, c.blendMode == .passThrough { c.blendMode = .normal }
        if let vm = group.vectorMask, !vm.isEmpty {
            intersectVectorMask(&c, vm.resolved.path)
            if c.effects.hasAny { c.vectorMaskHidesEffects = true }
        }
        if let j = groupJob {
            jobs[j].layerID = c.id
            if c.effects.hasAny { c.layerMaskHidesEffects = true }
        }
        if group.effects.hasAny {
            c.effects = group.effects
            c.vectorMaskHidesEffects = group.vectorMaskHidesEffects; c.layerMaskHidesEffects = group.layerMaskHidesEffects
        }
        if !group.isVisible { c.isVisible = false }
        if isNamed { c.name = group.name; named.insert(c.id) }
        report.groups -= 1
        return [c]
    }
}
