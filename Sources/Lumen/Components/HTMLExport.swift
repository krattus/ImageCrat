import AppKit
import CoreImage
import CoreText
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Export to HTML & CSS (design → web page)
//
// Text layers become real HTML text, rectangle / ellipse shapes become CSS boxes (background, border, radius,
// box-shadow), other vector shapes become inline SVG, pixels / smart objects become optimised image files, groups
// become nested elements. Whatever CSS cannot express (bevels, patterns, masks, warps, exotic blend modes, adjustment
// layers) is rasterised so the page still looks like the document.

struct HTMLExportOptions: Equatable {
    enum Layout: String, CaseIterable, Identifiable { case absolute = "Absolute", flex = "Flex / Auto Layout"; var id: String { rawValue } }
    enum Units: String, CaseIterable, Identifiable { case px, rem; var id: String { rawValue } }
    enum ImageFormat: String, CaseIterable, Identifiable { case auto = "Auto", png = "PNG", jpeg = "JPEG", webp = "WebP"; var id: String { rawValue } }

    var layout: Layout = .absolute
    var units: Units = .px
    var remBase: Double = 16
    var imageFormat: ImageFormat = .auto
    /// 0…100 (JPEG / WebP).
    var quality: Double = 85
    /// Also write @2x assets and reference them with `srcset`.
    var retina = true
    var cssVariables = true
    var semanticTags = true
    /// One .html file with the CSS embedded and the images as data URIs.
    var singleFile = false
    /// The page scales down to narrower viewports.
    var responsive = true
    /// Keep the document's line breaks in paragraph text (otherwise the browser re-wraps it).
    var preserveLineBreaks = true
    var title = "Untitled"
    /// Alt text per image layer id (defaults to the layer name).
    var altText: [UUID: String] = [:]
    /// Export only this artboard (nil = whole document).
    var artboardID: UUID? = nil
}

struct WebAsset {
    var name: String            // "hero.png"
    var mime: String
    var data: Data
    var name2x: String? = nil
    var data2x: Data? = nil
    var width: Int
    var height: Int
    var layerID: UUID
}

struct HTMLExportResult {
    var html: String
    /// Stylesheet (also embedded in `html` for single-file exports).
    var css: String
    var assets: [WebAsset]
    var warnings: [String]
    var pageSize: CGSize
    var elementCount = 0
    var textCount = 0
    var boxCount = 0
    var svgCount = 0
    /// (layer id, layer name, alt text) of every image element.
    var images: [(id: UUID, name: String, alt: String)] = []
    /// The document state the page was built from (artboard exports: the artboard alone).
    var state: DocumentState

    var totalBytes: Int { html.utf8.count + css.utf8.count + assets.reduce(0) { $0 + $1.data.count + ($1.data2x?.count ?? 0) } }
}

final class WebNode {
    enum Kind { case container, text, box, svg, image }
    var kind: Kind
    var layerID: UUID
    var name: String
    var cls = ""
    var tag = "div"
    /// Page-space box (before rotation).
    var frame: CGRect
    var rotation: Double = 0
    /// Visual declarations (no geometry).
    var decl: [(String, String)] = []
    var children: [WebNode] = []
    var inner = ""                 // inner HTML (text) or full SVG markup
    var asset: WebAsset?
    var alt = ""
    var fontSize: Double = 0
    var textLength = 0
    var borderWidth: Double = 0
    /// Flex container settings (auto layout inference).
    var flex: [(String, String)]? = nil
    var inFlow = false
    var attributes: [(String, String)] = []

    init(_ kind: Kind, layer: Layer, frame: CGRect) {
        self.kind = kind; self.layerID = layer.id; self.name = layer.name; self.frame = frame
    }
}

enum HTMLExporter {
    /// Builds the page for a document state.
    static func export(_ state: DocumentState, options: HTMLExportOptions) -> HTMLExportResult {
        var st = state
        if let ab = options.artboardID, let l = state.layer(ab), let a = AppActions.artboardState(state, l) { st = a }
        return HTMLExportBuilder(st, options).build()
    }

    /// Writes `index.html` (+ `style.css` and `assets/`) into a folder. Returns the HTML file.
    @discardableResult
    static func write(_ r: HTMLExportResult, to folder: URL, options: HTMLExportOptions, fileName: String = "index.html") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = folder.appendingPathComponent(fileName)
        try r.html.data(using: .utf8)!.write(to: page, options: .atomic)
        if !options.singleFile {
            try r.css.data(using: .utf8)!.write(to: folder.appendingPathComponent("style.css"), options: .atomic)
            if !r.assets.isEmpty {
                let dir = folder.appendingPathComponent("assets")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for a in r.assets {
                    try a.data.write(to: dir.appendingPathComponent(a.name), options: .atomic)
                    if let d2 = a.data2x, let n2 = a.name2x { try d2.write(to: dir.appendingPathComponent(n2), options: .atomic) }
                }
            }
        }
        return page
    }

    /// "Copy CSS": the declarations for one layer (position within the document included).
    static func css(for layer: Layer, in st: DocumentState, options: HTMLExportOptions = HTMLExportOptions()) -> String {
        var o = options
        o.cssVariables = false
        o.semanticTags = false
        o.layout = .absolute
        let b = HTMLExportBuilder(st, o)
        b.skipAssets = true
        guard let node = b.node(for: layer) else { return "/* \(layer.name): nothing to export (hidden or empty) */" }
        b.assignClasses([node])
        var rule = b.rule(for: node, parent: nil)
        if node.kind == .image { rule.insert(("/* pixels: export this layer as an image */", ""), at: 0) }
        var out = ".\(node.cls) {\n"
        for (k, v) in rule { out += v.isEmpty ? "  \(k)\n" : "  \(k): \(v);\n" }
        out += "}"
        for c in node.children {
            let r = b.rule(for: c, parent: node)
            out += "\n\n.\(c.cls) {\n" + r.map { "  \($0.0): \($0.1);\n" }.joined() + "}"
        }
        return b.finalizeColors(out, root: false).css
    }
}

final class HTMLExportBuilder {
    let st: DocumentState
    let opt: HTMLExportOptions
    let space: CanvasSpace
    var warnings: [String] = []
    var assets: [WebAsset] = []
    private var usedClasses = Set<String>()
    private var usedAssetNames = Set<String>()
    var skipAssets = false
    private lazy var st2x: DocumentState = Self.scaled(st, by: 2)
    private var svgDefCounter = 0

    init(_ st: DocumentState, _ opt: HTMLExportOptions) {
        self.st = st
        self.opt = opt
        self.space = CanvasSpace(width: st.width, height: st.height)
    }

    // MARK: Formatting helpers

    static func num(_ v: Double, _ digits: Int = 2) -> String {
        if !v.isFinite { return "0" }
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// A CSS length in the chosen unit.
    func len(_ v: Double) -> String {
        if abs(v) < 0.005 { return "0" }
        if opt.units == .rem { return Self.num(v / max(1, opt.remBase), 4) + "rem" }
        return Self.num(v) + "px"
    }
    func len(_ v: CGFloat) -> String { len(Double(v)) }

    /// Colour token: replaced at the end by a literal or a CSS variable.
    func col(_ c: RGBA, variable: Bool = true) -> String {
        let lit = Self.cssColor(c)
        return variable ? "«\(lit)»" : lit
    }

    static func cssColor(_ c: RGBA) -> String {
        if c.a >= 0.999 { return "#" + c.hex.lowercased() }
        return "rgba(\(c.r8), \(c.g8), \(c.b8), \(num(c.a, 3)))"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func escapeAttr(_ s: String) -> String { escape(s).replacingOccurrences(of: "\"", with: "&quot;") }

    static func slug(_ s: String) -> String {
        var out = ""
        var lastDash = true
        for u in s.lowercased().unicodeScalars {
            if (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) { out.unicodeScalars.append(u); lastDash = false }
            else if !lastDash { out += "-"; lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "layer" }
        if let f = out.unicodeScalars.first, f.value >= 48 && f.value <= 57 { out = "l-" + out }
        return String(out.prefix(32))
    }

    private func unique(_ base: String, in set: inout Set<String>) -> String {
        if !set.contains(base) { set.insert(base); return base }
        var i = 2
        while set.contains("\(base)-\(i)") { i += 1 }
        set.insert("\(base)-\(i)")
        return "\(base)-\(i)"
    }

    // MARK: Build

    func build() -> HTMLExportResult {
        var layers = st.layers
        // Page background: a uniform bottom layer becomes `background-color`.
        var pageBG: RGBA? = nil
        if let first = layers.first, first.isVisible, first.opacity >= 0.999, first.blendMode == .normal || first.blendMode == .passThrough,
           first.mask == nil, !first.effects.hasAny, let c = uniformColor(first) {
            pageBG = c
            layers.removeFirst()
            if layers.first?.isClipped == true { layers = st.layers; pageBG = nil }
        }
        let nodes = self.nodes(for: layers)
        let root = WebNode(.container, layer: Layer(name: "page", content: .group(GroupContent())), frame: st.canvasCGRect)
        root.children = nodes
        root.cls = "page"
        usedClasses.insert("page")
        assignClasses(nodes)
        if opt.semanticTags { applySemantics(root) }
        if opt.layout == .flex { for n in allNodes(root) where n.kind == .container && n !== root { inferFlex(n) } }

        // CSS
        var css = "*, *::before, *::after { box-sizing: border-box; }\n"
        css += "html, body { margin: 0; padding: 0; }\n"
        css += "body { background: \(pageBG.map { col($0) } ?? "#ffffff"); -webkit-font-smoothing: antialiased; }\n"
        css += ":where(.page) :where(h1, h2, h3, h4, p, figure, ul, ol) { margin: 0; padding: 0; font: inherit; }\n"
        css += ":where(.page) :where(button) { appearance: none; -webkit-appearance: none; border: 0; padding: 0; margin: 0; background: none; font: inherit; color: inherit; text-align: inherit; cursor: pointer; }\n"
        css += ":where(.page) :where(img, svg) { display: block; }\n"
        var pageDecl: [(String, String)] = [("position", "relative"), ("width", len(Double(st.width))), ("height", len(Double(st.height))), ("margin", "0 auto"), ("overflow", "hidden")]
        if let bg = pageBG { pageDecl.append(("background-color", col(bg))) }
        if opt.responsive && opt.units == .px { pageDecl.append(("transform-origin", "top left")) }
        if opt.responsive && opt.units == .rem {
            let base = Self.num(opt.remBase)
            css = "html { font-size: min(\(base)px, calc(100vw / \(Self.num(Double(st.width) / opt.remBase, 4)))); }\n" + css
        }
        css += ".page {\n" + pageDecl.map { "  \($0.0): \($0.1);\n" }.joined() + "}\n"
        for n in allNodes(root) where n !== root {
            let parent = parentOf(n, in: root)
            let r = rule(for: n, parent: parent === root ? nil : parent)
            css += "\n.\(n.cls) {\n" + r.map { "  \($0.0): \($0.1);\n" }.joined() + "}\n"
        }
        let fin = finalizeColors(css, root: opt.cssVariables)
        css = fin.css

        // HTML
        var body = ""
        emit(root, indent: 1, into: &body)
        var html = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
        html += "  <meta charset=\"utf-8\" />\n"
        html += "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
        html += "  <meta name=\"generator\" content=\"\(Brand.name)\" />\n"
        html += "  <title>\(Self.escape(opt.title))</title>\n"
        if opt.singleFile {
            html += "  <style>\n" + css.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\n  </style>\n"
        } else {
            html += "  <link rel=\"stylesheet\" href=\"style.css\" />\n"
        }
        html += "</head>\n<body>\n" + body
        if opt.responsive && opt.units == .px {
            // Scales the absolutely positioned page down to narrow viewports (no markup characters inside the script).
            html += "  <script>(function () { var p = document.querySelector('.page'), w = \(st.width), h = \(st.height); function fit() { var s = Math.min(1, document.documentElement.clientWidth / w); p.style.transform = s === 1 ? '' : 'scale(' + s + ')'; p.style.marginLeft = s === 1 ? '' : '0'; p.style.marginBottom = s === 1 ? '' : (h * (s - 1)) + 'px'; } fit(); window.addEventListener('resize', fit); })();</script>\n"
        }
        html += "</body>\n</html>\n"
        html = replaceColorTokens(html, map: fin.map)

        var res = HTMLExportResult(html: html, css: css, assets: assets, warnings: warnings, pageSize: CGSize(width: st.width, height: st.height), state: st)
        for n in allNodes(root) where n !== root {
            res.elementCount += 1
            switch n.kind {
            case .text: res.textCount += 1
            case .box: res.boxCount += 1
            case .svg: res.svgCount += 1
            case .image: res.images.append((n.layerID, n.name, n.alt))
            case .container: break
            }
        }
        return res
    }

    func allNodes(_ n: WebNode) -> [WebNode] { [n] + n.children.flatMap { allNodes($0) } }

    func parentOf(_ n: WebNode, in root: WebNode) -> WebNode? {
        for c in root.children {
            if c === n { return root }
            if let p = parentOf(n, in: c) { return p }
        }
        return nil
    }

    func assignClasses(_ nodes: [WebNode]) {
        for n in nodes {
            n.cls = unique(Self.slug(n.name), in: &usedClasses)
            assignClasses(n.children)
        }
    }

    // MARK: Colour variables

    private func replaceColorTokens(_ s: String, map: [String: String]) -> String {
        var out = ""
        var rest = Substring(s)
        while let a = rest.firstIndex(of: "«") {
            out += rest[rest.startIndex..<a]
            guard let b = rest[a...].firstIndex(of: "»") else { break }
            let lit = String(rest[rest.index(after: a)..<b])
            out += map[lit] ?? lit
            rest = rest[rest.index(after: b)...]
        }
        out += rest
        return out
    }

    /// Replaces colour tokens by literals or `var(--color-n)` and prepends the `:root` block.
    func finalizeColors(_ css: String, root: Bool) -> (css: String, map: [String: String]) {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var rest = Substring(css)
        while let a = rest.firstIndex(of: "«"), let b = rest[a...].firstIndex(of: "»") {
            let lit = String(rest[rest.index(after: a)..<b])
            if counts[lit] == nil { order.append(lit) }
            counts[lit, default: 0] += 1
            rest = rest[rest.index(after: b)...]
        }
        var map: [String: String] = [:]
        var vars = ""
        if root {
            let sorted = order.sorted { (counts[$0] ?? 0) != (counts[$1] ?? 0) ? (counts[$0] ?? 0) > (counts[$1] ?? 0) : order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
            var i = 1
            for lit in sorted {
                let name: String
                switch lit {
                case "#ffffff": name = "--color-white"
                case "#000000": name = "--color-black"
                default: name = "--color-\(i)"; i += 1
                }
                map[lit] = "var(\(name))"
                vars += "  \(name): \(lit);\n"
            }
        }
        var out = replaceColorTokens(css, map: map)
        if root && !vars.isEmpty { out = ":root {\n" + vars + "}\n" + out }
        return (out, map)
    }

    // MARK: Layer tree → nodes

    func nodes(for layers: [Layer]) -> [WebNode] {
        var out: [WebNode] = []
        var start = 0
        // Adjustment layers change everything below them: that part of the stack is flattened into one image.
        if let a = layers.lastIndex(where: { $0.isAdjustment && $0.isVisible && $0.opacity > 0.001 }) {
            var end = a + 1
            while end < layers.count && layers[end].isClipped { end += 1 }
            let run = Array(layers[0..<end])
            if let n = imageNode(layers: run, name: "backdrop", id: layers[a].id) {
                warnings.append("Adjustment layer “\(layers[a].name)” and the layers below it were flattened into one image.")
                out.append(n)
            }
            start = end
        }
        var i = start
        while i < layers.count {
            let l = layers[i]
            var j = i + 1
            while j < layers.count && layers[j].isClipped { j += 1 }
            defer { i = j }
            guard l.isVisible, l.opacity > 0.001 else { continue }
            if j > i + 1, layers[(i + 1)..<j].contains(where: { $0.isVisible }) {
                if let n = imageNode(layers: Array(layers[i..<j]), name: l.name, id: l.id) {
                    warnings.append("Clipping group on “\(l.name)” was rasterised.")
                    out.append(n)
                }
                continue
            }
            if let n = node(for: l) { out.append(n) }
        }
        return out
    }

    /// CSS `mix-blend-mode` keyword, or nil when CSS has no equivalent.
    static func cssBlend(_ m: BlendMode) -> String? {
        switch m {
        case .normal, .passThrough: return "normal"
        case .multiply: return "multiply"
        case .screen: return "screen"
        case .overlay: return "overlay"
        case .darken: return "darken"
        case .lighten: return "lighten"
        case .colorDodge: return "color-dodge"
        case .colorBurn: return "color-burn"
        case .hardLight: return "hard-light"
        case .softLight: return "soft-light"
        case .difference: return "difference"
        case .exclusion: return "exclusion"
        case .hue: return "hue"
        case .saturation: return "saturation"
        case .color: return "color"
        case .luminosity: return "luminosity"
        case .linearDodge: return "plus-lighter"
        default: return nil
        }
    }

    /// Things no element type can express in CSS: the layer must be rasterised.
    private func needsRaster(_ l: Layer) -> String? {
        if let m = l.mask, m.isEnabled { return "layer mask" }
        if !l.blendIf.isDefault { return "Blend If" }
        if l.knockout != .none { return "knockout" }
        if !(l.channelR && l.channelG && l.channelB) { return "channel restriction" }
        return nil
    }

    private func commonDecl(_ n: WebNode, _ l: Layer, opacity: Double? = nil) {
        let o = opacity ?? l.opacity
        if o < 0.999 { n.decl.append(("opacity", Self.num(o, 3))) }
        if l.blendMode != .normal && l.blendMode != .passThrough {
            if let b = Self.cssBlend(l.blendMode) { n.decl.append(("mix-blend-mode", b)) }
            else { warnings.append("Blend mode “\(l.blendMode.displayName)” of “\(l.name)” has no CSS equivalent (exported as Normal).") }
        }
    }

    func node(for l: Layer) -> WebNode? {
        guard l.isVisible, l.opacity > 0.001 else { return nil }
        if let why = needsRaster(l), !l.isRaster, !l.isSmartObject {
            warnings.append("“\(l.name)” was rasterised (\(why)).")
            return imageNode(layers: [l], name: l.name, id: l.id)
        }
        switch l.content {
        case .group(let g): return groupNode(l, g)
        case .text(let t): return textNode(l, t) ?? rasterFallback(l, "text features without a CSS equivalent")
        case .shape(let s): return shapeNode(l, s) ?? rasterFallback(l, "effects without a CSS equivalent")
        case .fill(let f): return fillNode(l, f) ?? imageNode(layers: [l], name: l.name, id: l.id)
        case .adjustment: return nil
        case .raster, .smartObject: return imageNode(layers: [l], name: l.name, id: l.id)
        }
    }

    private func rasterFallback(_ l: Layer, _ why: String) -> WebNode? {
        warnings.append("“\(l.name)” was rasterised (\(why)).")
        return imageNode(layers: [l], name: l.name, id: l.id)
    }

    // MARK: Groups

    private func groupNode(_ l: Layer, _ g: GroupContent) -> WebNode? {
        let fx = l.effects.enabled && l.effects.hasAny
        var clipRadius: String? = nil
        var clipRect: CGRect? = nil
        if let vm = l.vectorMask, l.vectorMaskEnabled, !vm.isEmpty {
            if let (r, rad) = Self.rectOrEllipse(vm) { clipRect = r; clipRadius = rad }
            else { return rasterFallback(l, "vector mask") }
        }
        let onlyShadow = fx && Self.onlyDropShadows(l.effects)
        if fx && !onlyShadow { return rasterFallback(l, "layer style on a group") }
        if l.fillOpacity < 0.999 { return rasterFallback(l, "fill opacity on a group") }
        if l.blendMode != .normal && l.blendMode != .passThrough && Self.cssBlend(l.blendMode) == nil { return rasterFallback(l, "blend mode \(l.blendMode.displayName)") }
        let kids = nodes(for: g.children)
        var frame: CGRect
        if let ab = g.artboard { frame = ab.rect }
        else if let c = clipRect { frame = c }
        else {
            guard !kids.isEmpty else { return nil }
            frame = kids.reduce(CGRect.null) { $0.union(rotatedBounds($1)) }
        }
        guard frame.width > 0, frame.height > 0 else { return nil }
        let n = WebNode(.container, layer: l, frame: frame)
        n.children = kids
        if let ab = g.artboard {
            if let bg = ab.background { n.decl.append(("background-color", col(bg))) }
            n.decl.append(("overflow", "hidden"))
        } else if clipRect != nil {
            n.decl.append(("overflow", "hidden"))
            if let r = clipRadius { n.decl.append(("border-radius", r)) }
        }
        if l.blendMode != .passThrough { n.decl.append(("isolation", "isolate")) }
        if onlyShadow { n.decl.append(("filter", l.effects.dropShadows.filter(\.enabled).map { "drop-shadow(\(shadowValue($0, spread: false)))" }.joined(separator: " "))) }
        commonDecl(n, l)
        return n
    }

    private func rotatedBounds(_ n: WebNode) -> CGRect {
        guard abs(n.rotation) > 0.01 else { return n.frame }
        let t = CGAffineTransform(translationX: n.frame.midX, y: n.frame.midY).rotated(by: CGFloat(n.rotation * .pi / 180)).translatedBy(x: -n.frame.midX, y: -n.frame.midY)
        return n.frame.applying(t)
    }

    static func onlyDropShadows(_ fx: LayerEffects) -> Bool {
        var f = fx
        f.dropShadow.enabled = false
        f.extraDropShadows = []
        return !f.hasAny
    }

    /// A vector mask that is an axis-aligned rectangle (→ `overflow: hidden`) or ellipse (→ radius 50%).
    static func rectOrEllipse(_ vm: VectorPath) -> (CGRect, String?)? {
        guard vm.subpaths.count == 1, let sp = vm.subpaths.first, sp.closed, sp.points.count == 4 else { return nil }
        let b = vm.bounds
        if sp.points.allSatisfy({ !$0.hasHandles }) {
            let xs = Set(sp.points.map { ($0.anchor.x * 100).rounded() }), ys = Set(sp.points.map { ($0.anchor.y * 100).rounded() })
            return xs.count == 2 && ys.count == 2 ? (b, nil) : nil
        }
        // ellipse: anchors at the mid-points of the bounds' edges
        let mids = [CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.maxX, y: b.midY), CGPoint(x: b.midX, y: b.maxY), CGPoint(x: b.minX, y: b.midY)]
        let ok = sp.points.allSatisfy { p in mids.contains { $0.distance(to: p.anchor) < 0.6 } && p.hasHandles }
        return ok ? (b, "50%") : nil
    }

    // MARK: Fill layers

    private func uniformColor(_ l: Layer) -> RGBA? {
        if case .fill(let f) = l.content, let c = f.paint.solidColor, c.a >= 0.999 { return c }
        guard let r = l.raster, r.frame.intersection(st.canvasRect) == st.canvasRect else { return nil }
        let b = r.buffer
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        let x0 = -r.origin.x, y0 = -r.origin.y
        let first = p + y0 * b.bytesPerRow + x0 * 4
        let (fr, fg, fb, fa) = (first[0], first[1], first[2], first[3])
        guard fa == 255 else { return nil }
        for y in y0..<(y0 + st.height) {
            let row = p + y * b.bytesPerRow + x0 * 4
            for x in 0..<st.width {
                let q = row + x * 4
                if q[0] != fr || q[1] != fg || q[2] != fb || q[3] != 255 { return nil }
            }
        }
        return RGBA(r8: fr, g8: fg, b8: fb)
    }

    private func fillNode(_ l: Layer, _ f: FillContent) -> WebNode? {
        guard !(l.effects.enabled && l.effects.hasAny), l.vectorMask == nil || !l.vectorMaskEnabled, l.fillOpacity >= 0.999 else { return nil }
        let frame = st.canvasCGRect
        guard let bg = background(f.paint, bounds: frame, ref: frame) else { return nil }
        let n = WebNode(.box, layer: l, frame: frame)
        n.decl.append(bg)
        commonDecl(n, l)
        return n
    }

    // MARK: Paint → CSS

    /// `background-color` / `background` declaration for a paint, or nil when CSS cannot express it.
    func background(_ paint: PaintStyle, bounds: CGRect, ref: CGRect) -> (String, String)? {
        switch paint {
        case .none: return ("background", "none")
        case .color(let c): return ("background-color", col(c))
        case .gradient(let g): return cssGradient(g, box: bounds, ref: ref).map { ("background", $0) }
        case .pattern: return nil
        }
    }

    /// `linear-gradient(...)` / `radial-gradient(...)` for a gradient fill placed in `box` (page space).
    func cssGradient(_ gf: GradientFill, box: CGRect, ref: CGRect) -> String? {
        guard gf.type == .linear || gf.type == .radial, gf.gradient.stops.count >= 2, box.width > 0, box.height > 0 else { return nil }
        let (s, e) = gf.endpoints(in: ref)
        let grad = gf.reverse ? gf.gradient.reversed() : gf.gradient
        let stops = grad.sortedStops
        if gf.type == .radial {
            let r = Double(s.distance(to: e))
            guard r > 0.01 else { return nil }
            let list = stops.map { "\(col($0.color)) \(len($0.location * r))" }.joined(separator: ", ")
            return "radial-gradient(circle \(len(r)) at \(len(s.x - box.minX)) \(len(s.y - box.minY)), \(list))"
        }
        let d = e - s
        guard d.length > 0.01 else { return nil }
        // CSS angle: 0deg = to top, clockwise. The CSS gradient line runs through the box centre with length
        // |w·sinθ| + |h·cosθ|; our start/end are projected onto it so the colours land in the same place.
        let theta = atan2(Double(d.x), Double(-d.y))
        let dir = CGPoint(x: sin(theta), y: -cos(theta))
        let L = abs(Double(box.width) * sin(theta)) + abs(Double(box.height) * cos(theta))
        guard L > 0.01 else { return nil }
        let c = box.center
        func t(_ p: CGPoint) -> Double { Double((p - c).dot(dir)) / L + 0.5 }
        let t0 = t(s), t1 = t(e)
        let list = stops.map { "\(col($0.color)) \(Self.num((t0 + $0.location * (t1 - t0)) * 100))%" }.joined(separator: ", ")
        var deg = theta * 180 / .pi
        if deg < 0 { deg += 360 }
        return "linear-gradient(\(Self.num(deg))deg, \(list))"
    }

    // MARK: Effects → CSS

    private func lightAngle(_ useGlobal: Bool, _ angle: Double) -> Double { useGlobal ? st.globalLight.angle : angle }

    /// "dx dy blur [spread] colour" for a drop / inner shadow. The renderer blurs with σ = (size − spread) / 2.2;
    /// CSS blur radii are 2σ.
    func shadowValue(_ d: ShadowEffect, spread withSpread: Bool, scale: Double = 1) -> String {
        let a = lightAngle(d.useGlobalLight, d.angle) * .pi / 180
        let dx = -cos(a) * d.distance * scale, dy = sin(a) * d.distance * scale
        let spread = d.size * d.spread / 100 * scale
        let blur = max(0, d.size * scale - spread) / 1.1
        var parts = [len(dx), len(dy), len(blur)]
        if withSpread && spread > 0.01 { parts.append(len(spread)) }
        parts.append(Self.cssColor(d.color.withAlpha(d.color.a * d.opacity)))
        return parts.joined(separator: " ")
    }

    /// Splits the effects of a box-like layer into CSS declarations. Returns nil when something cannot be expressed.
    private func boxEffects(_ fx: LayerEffects) -> (shadows: [String], background: (String, String)?, ok: Bool) {
        guard fx.enabled, fx.hasAny else { return ([], nil, true) }
        if fx.bevel.enabled || fx.satin.enabled || fx.patternOverlay.enabled { return ([], nil, false) }
        var shadows: [String] = []
        for s in fx.strokes where s.enabled && s.size > 0 {
            guard case .color(let c) = s.paint, s.blendMode == .normal else { return ([], nil, false) }
            let cc = Self.cssColor(c.withAlpha(c.a * s.opacity))
            switch s.position {
            case .outside: shadows.append("0 0 0 \(len(s.size)) \(cc)")
            case .inside: shadows.append("inset 0 0 0 \(len(s.size)) \(cc)")
            case .center:
                shadows.append("0 0 0 \(len(s.size / 2)) \(cc)")
                shadows.append("inset 0 0 0 \(len(s.size / 2)) \(cc)")
            }
        }
        for s in fx.innerShadows where s.enabled { shadows.append("inset " + shadowValue(s, spread: true)) }
        if fx.innerGlow.enabled {
            let g = fx.innerGlow
            if g.useGradient || g.source == .center { return ([], nil, false) }
            shadows.append("inset 0 0 \(len(g.size / 1.1)) \(len(g.size * g.spread / 100)) \(Self.cssColor(g.color.withAlpha(g.opacity)))")
        }
        if fx.outerGlow.enabled {
            let g = fx.outerGlow
            if g.useGradient { return ([], nil, false) }
            shadows.append("0 0 \(len(g.size / 1.1)) \(len(g.size * g.spread / 100)) \(Self.cssColor(g.color.withAlpha(g.opacity)))")
        }
        for s in fx.dropShadows where s.enabled { shadows.append(shadowValue(s, spread: true)) }
        var bg: (String, String)? = nil
        if let g = fx.gradientOverlays.first(where: { $0.enabled }) {
            guard g.blendMode == .normal, g.opacity >= 0.999 else { return ([], nil, false) }
            bg = ("gradient", "")      // resolved by the caller (needs the box)
            _ = g
        }
        if let c = fx.colorOverlays.first(where: { $0.enabled }) {
            guard c.blendMode == .normal, c.opacity >= 0.999 else { return ([], nil, false) }
            bg = ("background-color", col(c.color))
        }
        return (shadows, bg, true)
    }

    // MARK: Shapes

    /// (rotation°, sx, sy) of an affine transform without shear, or nil.
    static func decompose(_ t: CGAffineTransform) -> (rotation: Double, sx: Double, sy: Double)? {
        let ux = Double(t.a), uy = Double(t.b), vx = Double(t.c), vy = Double(t.d)
        let lu = hypot(ux, uy), lv = hypot(vx, vy)
        guard lu > 1e-6, lv > 1e-6 else { return nil }
        if abs(ux * vx + uy * vy) / (lu * lv) > 0.002 { return nil }        // sheared
        return (atan2(uy, ux) * 180 / .pi, lu, lv)
    }

    private func shapeNode(_ l: Layer, _ s: ShapeContent) -> WebNode? {
        let hasFX = l.effects.enabled && l.effects.hasAny
        if l.vectorMask != nil && l.vectorMaskEnabled { return nil }
        if l.fillOpacity < 0.999 && hasFX { return nil }
        // CSS box: rectangle / rounded rectangle / ellipse with a shear-free transform
        var rect: CGRect? = nil
        var radius = 0.0
        var ellipse = false
        switch s.geometry {
        case .rectangle(let r, let rad): rect = r; radius = rad
        case .ellipse(let r): rect = r; ellipse = true
        default: break
        }
        if let r = rect, s.perspective == nil, let dec = Self.decompose(s.transform), let boxNode = cssBox(l, s, rect: r, radius: radius, ellipse: ellipse, dec: dec) {
            return boxNode
        }
        return svgNode(l, s)
    }

    private func cssBox(_ l: Layer, _ s: ShapeContent, rect r: CGRect, radius: Double, ellipse: Bool, dec: (rotation: Double, sx: Double, sy: Double)) -> WebNode? {
        let fx = boxEffects(l.effects)
        guard fx.ok else { return nil }
        let w = Double(r.width) * dec.sx, h = Double(r.height) * dec.sy
        guard w > 0.01, h > 0.01 else { return nil }
        let c = r.center.applying(s.transform)
        var frame = CGRect(x: Double(c.x) - w / 2, y: Double(c.y) - h / 2, width: w, height: h)
        let n = WebNode(.box, layer: l, frame: frame)
        if abs(dec.rotation) > 0.01 { n.rotation = dec.rotation }
        var rx = min(radius * dec.sx, w / 2), ry = min(radius * dec.sy, h / 2)
        // stroke → border (the box grows for centred / outside strokes)
        var border: (String, String)? = nil
        var clipPadding = false
        if !s.stroke.paint.isNone && s.stroke.width > 0 {
            guard case .color(let sc) = s.stroke.paint else { return nil }
            let sw = s.stroke.width * (dec.sx + dec.sy) / 2
            var grow = 0.0
            switch s.stroke.alignment {
            case .inside: grow = 0
            case .center: grow = sw / 2
            case .outside: grow = sw
            }
            frame = frame.insetBy(dx: -grow, dy: -grow)
            n.frame = frame
            if rx > 0 || ry > 0 { rx += grow; ry += grow }
            border = ("border", "\(len(sw)) \(s.stroke.dash.isEmpty ? "solid" : "dashed") \(col(sc))")
            n.borderWidth = sw
            clipPadding = grow > 0 && sc.a < 0.999
        }
        // fill
        var fillPaint = s.fill
        if l.fillOpacity < 0.999, case .color(let c0) = fillPaint { fillPaint = .color(c0.withAlpha(c0.a * l.fillOpacity)) }
        let pathBounds = s.path.bounds
        var isGradient = false
        if case .gradient = fillPaint {
            if abs(dec.rotation) > 0.01 { return nil }       // gradient end points live in document space
            isGradient = true
        }
        guard let bg = background(fillPaint, bounds: frame, ref: pathBounds) else { return nil }
        if !(bg.0 == "background" && bg.1 == "none") { n.decl.append(bg) }
        if let over = fx.background {
            n.decl.removeAll { $0.0 == "background-color" || $0.0 == "background" }
            if over.0 == "gradient" {
                guard abs(dec.rotation) <= 0.01, let g = l.effects.gradientOverlays.first(where: { $0.enabled }), let v = cssGradient(g.fill, box: frame, ref: pathBounds) else { return nil }
                n.decl.append(("background", v))
                isGradient = true
            } else {
                n.decl.append(over)
                isGradient = false
            }
        }
        if let b = border {
            n.decl.append(b)
            if isGradient { n.decl.append(("background-origin", "border-box")) }
            if clipPadding { n.decl.append(("background-clip", "padding-box")) }
        }
        if ellipse { n.decl.append(("border-radius", "50%")) }
        else if rx > 0.01 || ry > 0.01 {
            n.decl.append(("border-radius", abs(rx - ry) < 0.01 ? len(rx) : "\(len(rx)) / \(len(ry))"))
        }
        if !fx.shadows.isEmpty { n.decl.append(("box-shadow", fx.shadows.joined(separator: ", "))) }
        commonDecl(n, l)
        return n
    }

    // MARK: SVG

    private func svgNode(_ l: Layer, _ s: ShapeContent) -> WebNode? {
        let fx = l.effects
        var overlay: RGBA? = nil
        var filter: String? = nil
        if fx.enabled && fx.hasAny {
            var rest = fx
            rest.dropShadow.enabled = false; rest.extraDropShadows = []
            if let c = fx.colorOverlays.first(where: { $0.enabled }), c.blendMode == .normal, c.opacity >= 0.999 {
                overlay = c.color
                rest.colorOverlay.enabled = false; rest.extraColorOverlays = []
            }
            if rest.hasAny { return nil }
            let ds = fx.dropShadows.filter(\.enabled)
            if !ds.isEmpty { filter = ds.map { "drop-shadow(\(shadowValue($0, spread: false)))" }.joined(separator: " ") }
        }
        var sc = s
        if let c = overlay { sc.fill = .color(c) }
        if l.fillOpacity < 0.999, case .color(let c0) = sc.fill { sc.fill = .color(c0.withAlpha(c0.a * l.fillOpacity)) }
        if case .pattern = sc.fill { return nil }
        if case .pattern = sc.stroke.paint { return nil }
        let b = ShapeRenderer.docBounds(sc).insetBy(dx: 2, dy: 2).integral.insetBy(dx: -1, dy: -1)
        guard b.width > 0, b.height > 0 else { return nil }
        svgDefCounter += 1
        let markup = LayerSVGExport.markup(for: sc, viewBox: b, idPrefix: "g\(svgDefCounter)", standalone: false, color: { self.col($0) })
        let n = WebNode(.svg, layer: l, frame: b)
        n.inner = markup
        if let f = filter { n.decl.append(("filter", f)) }
        commonDecl(n, l)
        return n
    }

    // MARK: Text

    struct FontInfo {
        var family: String
        var stack: String
        var weight: Int
        var italic: Bool
        var ascent: Double
        var descent: Double
    }

    static func fontInfo(_ name: String, size: Double, fauxBold: Bool = false, fauxItalic: Bool = false) -> FontInfo {
        let ct = TextRenderer.makeFont(name: name, size: CGFloat(size))
        let family = CTFontCopyFamilyName(ct) as String
        let traits = CTFontCopyTraits(ct) as NSDictionary
        let w = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let sym = CTFontGetSymbolicTraits(ct)
        let table: [(Int, Double)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        var weight = table.min { abs($0.1 - w) < abs($1.1 - w) }?.0 ?? 400
        if fauxBold { weight = max(weight, 700) }
        let italic = sym.contains(.traitItalic) || fauxItalic
        let cls = (sym.rawValue >> 28) & 0xF
        let lower = family.lowercased()
        let serifNames = ["times", "georgia", "garamond", "baskerville", "palatino", "didot", "bodoni", "serif", "charter", "hoefler", "cochin", "new york"]
        var generic = "sans-serif"
        if sym.contains(.traitMonoSpace) || ["menlo", "monaco", "courier", "sf mono", "mono"].contains(where: { lower.contains($0) }) { generic = "monospace" }
        else if (1...5).contains(cls) || cls == 7 || (serifNames.contains { lower.contains($0) } && !lower.contains("sans")) { generic = "serif" }
        else if cls == 10 { generic = "cursive" }
        var stack: [String]
        if family.hasPrefix(".") || lower.hasPrefix("sf pro") || lower == "system font" {
            stack = ["-apple-system", "BlinkMacSystemFont", "\"Segoe UI\"", "Roboto", "\"Helvetica Neue\"", "Arial", "sans-serif"]
        } else {
            let q = family.contains(" ") ? "\"\(family)\"" : family
            switch generic {
            case "monospace": stack = [q, "ui-monospace", "SFMono-Regular", "Menlo", "Consolas", "monospace"]
            case "serif": stack = [q, "Georgia", "\"Times New Roman\"", "Times", "serif"]
            case "cursive": stack = [q, "cursive"]
            default: stack = [q, "\"Helvetica Neue\"", "Helvetica", "Arial", "sans-serif"]
            }
        }
        var seen = Set<String>()
        stack = stack.filter { seen.insert($0.lowercased()).inserted }
        var asc = Double(CTFontGetAscent(ct)), desc = Double(CTFontGetDescent(ct))
        // WebKit raises the ascent of the classic Mac fonts by 15% to match their Windows counterparts.
        if ["Times", "Helvetica", "Courier"].contains(family) { asc += ((asc + desc) * 0.15).rounded() }
        asc = asc.rounded(); desc = desc.rounded()
        return FontInfo(family: family, stack: stack.joined(separator: ", "), weight: weight, italic: italic, ascent: asc, descent: desc)
    }

    private func textNode(_ l: Layer, _ t: TextContent) -> WebNode? {
        guard t.warp == nil || t.warp!.isIdentity, t.pathText == nil, t.area == nil, t.orientation == .horizontal, t.list == nil, t.fitToBox == nil else { return nil }
        if l.vectorMask != nil && l.vectorMaskEnabled { return nil }
        guard let dec = Self.decompose(TextRenderer.docTransform(t)), abs(dec.sx - dec.sy) / max(dec.sx, dec.sy) < 0.01 else { return nil }
        let s = dec.sy
        let L = TextRenderer.layout(t)
        let lines = L.lines.filter { !$0.isMarker && $0.textRange.location != NSNotFound }
        guard !lines.isEmpty, !L.overflowed else { return nil }
        // effects
        let fx = l.effects
        var shadows: [String] = []
        var color = t.color
        var strokeDecl: [(String, String)] = []
        var gradientText: String? = nil
        if fx.enabled && fx.hasAny {
            if fx.bevel.enabled || fx.satin.enabled || fx.patternOverlay.enabled || fx.innerGlow.enabled || fx.innerShadows.contains(where: { $0.enabled }) { return nil }
            if fx.outerGlow.enabled {
                if fx.outerGlow.useGradient { return nil }
                shadows.append("0 0 \(len(fx.outerGlow.size / 1.1)) \(Self.cssColor(fx.outerGlow.color.withAlpha(fx.outerGlow.opacity)))")
            }
            for d in fx.dropShadows where d.enabled { shadows.append(shadowValue(d, spread: false)) }
            if let c = fx.colorOverlays.first(where: { $0.enabled }) {
                guard c.blendMode == .normal, c.opacity >= 0.999 else { return nil }
                color = c.color
            }
            let strokes = fx.strokes.filter { $0.enabled && $0.size > 0 }
            if strokes.count > 1 { return nil }
            if let sk = strokes.first {
                guard case .color(let c) = sk.paint, sk.blendMode == .normal, sk.position != .inside else { return nil }
                let w = sk.position == .outside ? sk.size * 2 : sk.size
                strokeDecl = [("-webkit-text-stroke", "\(len(w)) \(Self.cssColor(c.withAlpha(c.a * sk.opacity)))"), ("paint-order", "stroke fill")]
            }
            if fx.gradientOverlays.contains(where: { $0.enabled }) { gradientText = "" }
        }
        if l.fillOpacity < 0.999 { if fx.enabled && fx.hasAny { return nil }; color = color.withAlpha(color.a * l.fillOpacity) }

        let size = t.fontSize * s
        let info = Self.fontInfo(t.fontName, size: size, fauxBold: t.fauxBold, fauxItalic: t.fauxItalic)
        let mixedSizes = t.runs.contains { $0.style.fontSize != nil }
        let lh = t.leading ?? t.fontSize * Double(TextRenderer.autoLeadingFactor)
        // Local box: WebKit puts the first baseline floor((LH + A − D) / 2) CSS px below the top of the line box
        // (A, D: the font's rounded ascent / descent at the CSS font size).
        let baseline0 = Double(lines[0].transform.ty)
        let topLocal = baseline0 - ((lh * s + info.ascent - info.descent) / 2).rounded(.down) / s
        var x0: Double, width: Double
        var height = lh * Double(lines.count)
        let lineUnion = lines.reduce(CGRect.null) { $0.union($1.bounds) }
        if let box = t.boxSize {
            x0 = 1; width = max(1, Double(box.width) - 1)
            height = max(height, Double(box.height) - max(0, topLocal))
        } else {
            x0 = Double(lineUnion.minX); width = Double(lineUnion.width)
        }
        let localRect = CGRect(x: x0, y: topLocal, width: width, height: height)
        let M = TextRenderer.docTransform(t)
        let c = localRect.center.applying(M)
        let w = width * s, h = height * s
        let n = WebNode(.text, layer: l, frame: CGRect(x: Double(c.x) - w / 2, y: Double(c.y) - h / 2, width: w, height: h))
        if abs(dec.rotation) > 0.01 { n.rotation = dec.rotation }
        n.fontSize = size
        n.textLength = t.text.count
        n.tag = opt.semanticTags ? "p" : "div"

        // inner HTML: one entry per layout line (soft wraps kept), spans for styled ranges
        let ns = t.text as NSString
        let segs = t.styleSegments()
        let justified = t.alignment.isJustified
        let keepBreaks = t.boxSize == nil || (opt.preserveLineBreaks && !justified && opt.layout == .absolute)
        func spans(_ range: NSRange) -> String {
            var out = ""
            var pieces: [(NSRange, CharacterStyle)] = []
            if segs.isEmpty { pieces = [(range, CharacterStyle())] }
            for sg in segs {
                let lo = max(sg.location, range.location), hi = min(sg.end, range.location + range.length)
                if hi > lo { pieces.append((NSRange(location: lo, length: hi - lo), sg.style.normalized(against: t))) }
            }
            for (r, style) in pieces {
                let txt = Self.escape(ns.substring(with: r))
                let css = runCSS(style, base: t, scale: s)
                out += css.isEmpty ? txt : "<span style=\"\(css)\">\(txt)</span>"
            }
            return out
        }
        if keepBreaks {
            var parts: [String] = []
            for ln in lines {
                var r = ln.textRange
                // trailing white space / the newline itself does not belong to the visible line
                while r.length > 0, let u = UnicodeScalar(ns.character(at: r.location + r.length - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { r.length -= 1 }
                parts.append(spans(r))
            }
            // hard breaks (and blank paragraphs) come from the text between two layout lines; a soft wrap is one break
            var ends: [Int] = []
            for ln in lines {
                var r = ln.textRange
                while r.length > 0, let u = UnicodeScalar(ns.character(at: r.location + r.length - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { r.length -= 1 }
                ends.append(r.location + r.length)
            }
            var html = parts[0]
            for i in 1..<max(1, lines.count) {
                let start = lines[i].textRange.location
                let between = start > ends[i - 1] ? ns.substring(with: NSRange(location: ends[i - 1], length: start - ends[i - 1])).replacingOccurrences(of: "\r\n", with: "\n") : ""
                let k = between.unicodeScalars.filter { $0 == "\n" || $0 == "\r" || $0.value == 0x2029 || $0.value == 0x2028 }.count
                html += String(repeating: "\n", count: max(1, k)) + parts[i]
            }
            n.inner = html
            n.decl.append(("white-space", "pre"))
        } else {
            n.inner = spans(NSRange(location: 0, length: ns.length))
            n.decl.append(("white-space", "pre-wrap"))
        }

        n.decl.append(("font-family", info.stack))
        n.decl.append(("font-size", len(size)))
        n.decl.append(("font-weight", "\(info.weight)"))
        if info.italic { n.decl.append(("font-style", "italic")) }
        n.decl.append(("line-height", t.leading == nil && mixedSizes ? Self.num(Double(TextRenderer.autoLeadingFactor), 3) : len(lh * s)))
        if abs(t.tracking) > 0.01 { n.decl.append(("letter-spacing", Self.num(t.tracking / 1000, 4) + "em")) }
        n.decl.append(("color", col(color)))
        let align: String
        switch t.alignment {
        case .left: align = "left"
        case .center: align = "center"
        case .right: align = "right"
        default: align = "justify"
        }
        if align != "left" { n.decl.append(("text-align", align)) }
        var deco: [String] = []
        if t.underline { deco.append("underline") }
        if t.strikethrough { deco.append("line-through") }
        if !deco.isEmpty { n.decl.append(("text-decoration", deco.joined(separator: " "))) }
        if t.allCaps { n.decl.append(("text-transform", "uppercase")) }
        if t.hyphenate && !keepBreaks { n.decl.append(("hyphens", "auto")) }
        if !shadows.isEmpty { n.decl.append(("text-shadow", shadows.joined(separator: ", "))) }
        n.decl += strokeDecl
        if gradientText != nil, let g = fx.gradientOverlays.first(where: { $0.enabled }) {
            guard g.blendMode == .normal, g.opacity >= 0.999, let v = cssGradient(g.fill, box: n.frame, ref: TextRenderer.docBounds(t)) else { return nil }
            n.decl.append(("background", v))
            n.decl.append(("-webkit-background-clip", "text"))
            n.decl.append(("background-clip", "text"))
            n.decl.removeAll { $0.0 == "color" }
            n.decl.append(("color", "transparent"))
        }
        commonDecl(n, l)
        return n
    }

    private func lineEndsWithNewline(_ ns: NSString, _ r: NSRange) -> Bool {
        guard r.length > 0 else { return false }
        return TextRenderer.isNewline(ns.character(at: r.location + r.length - 1))
    }

    /// Inline style for a run's overrides.
    private func runCSS(_ s: CharacterStyle, base t: TextContent, scale: Double) -> String {
        if s.isEmpty { return "" }
        var d: [String] = []
        if s.fontName != nil || s.fauxBold != nil || s.fauxItalic != nil {
            let info = Self.fontInfo(s.fontName ?? t.fontName, size: t.fontSize, fauxBold: s.fauxBold ?? t.fauxBold, fauxItalic: s.fauxItalic ?? t.fauxItalic)
            if s.fontName != nil { d.append("font-family: \(info.stack.replacingOccurrences(of: "\"", with: "'"))") }
            d.append("font-weight: \(info.weight)")
            d.append("font-style: \(info.italic ? "italic" : "normal")")
        }
        if let v = s.fontSize { d.append("font-size: \(len(v * scale))") }
        if let c = s.color { d.append("color: \(col(c))") }
        if let v = s.tracking { d.append("letter-spacing: \(Self.num(v / 1000, 4))em") }
        if s.underline != nil || s.strikethrough != nil {
            var deco: [String] = []
            if s.underline ?? t.underline { deco.append("underline") }
            if s.strikethrough ?? t.strikethrough { deco.append("line-through") }
            d.append("text-decoration: \(deco.isEmpty ? "none" : deco.joined(separator: " "))")
        }
        if let v = s.baselineShift, abs(v) > 0.01 { d.append("position: relative; top: \(len(-v * scale))") }
        return d.joined(separator: "; ")
    }

    // MARK: Images

    static func scaled(_ st: DocumentState, by k: Double) -> DocumentState {
        var out = st
        out.width = Int((Double(st.width) * k).rounded())
        out.height = Int((Double(st.height) * k).rounded())
        let sp = CanvasSpace(width: out.width, height: out.height)
        let h = Homography(affine: CGAffineTransform(scaleX: CGFloat(k), y: CGFloat(k)))
        out.layers = st.layers.map { LayerTransformer.apply(h, to: $0, space: sp, scaleEffects: k, document: true) }
        out.selection = nil
        return out
    }

    private func appearance(_ layers: [Layer], in state: DocumentState) -> CIImage {
        let sp = CanvasSpace(width: state.width, height: state.height)
        var ls = layers
        if !ls.isEmpty {
            ls[0].isClipped = false
            if ls.count == 1 { ls[0].opacity = 1; ls[0].blendMode = .normal }
        }
        return Compositor.shared.composite(layers: ls, backdrop: CIImage.clearImage.cropped(to: sp.ciCanvas), space: sp, options: Compositor.Options(globalLight: state.globalLight))
    }

    /// Renders layers (appearance incl. masks and effects; a single layer without its own opacity / blend mode, which
    /// stay in CSS) into an image element cropped to its visible pixels.
    func imageNode(layers: [Layer], name: String, id: UUID) -> WebNode? {
        guard let first = layers.first else { return nil }
        let img = appearance(layers, in: st)
        let full = RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: space)
        guard let ob = full.opaqueBounds() else { return nil }
        let n = WebNode(.image, layer: first, frame: ob.cgRect)
        n.layerID = id
        n.name = name
        n.tag = "img"
        n.alt = opt.altText[id] ?? name
        if layers.count == 1 { commonDecl(n, first) }
        if skipAssets { return n }
        let crop = full.cropped(to: ob)
        let cg = crop.makeCGImage()
        let opaque = Self.isOpaque(crop)
        var format = opt.imageFormat
        if format == .auto { format = opaque ? .jpeg : .png }
        if format == .jpeg && !opaque { format = .png }           // JPEG cannot hold the transparency
        if format == .webp && !WebFormat.available.contains(.webp) { format = opaque ? .jpeg : .png }
        func encode(_ image: CGImage) -> Data? {
            var s = WebSettings()
            s.quality = opt.quality
            switch format {
            case .jpeg: s.format = .jpeg
            case .webp: s.format = .webp
            default: s.format = .png24
            }
            s.transparency = true
            return WebEncoder.encode(image, s)?.data
        }
        guard let data = encode(cg) else { return nil }
        let ext = format == .jpeg ? "jpg" : (format == .webp ? "webp" : "png")
        let mime = format == .jpeg ? "image/jpeg" : (format == .webp ? "image/webp" : "image/png")
        let base = unique(Self.slug(name), in: &usedAssetNames)
        var asset = WebAsset(name: "\(base).\(ext)", mime: mime, data: data, width: ob.width, height: ob.height, layerID: id)
        if opt.retina {
            // re-render at 2× from a scaled copy of the document, so vectors, text and smart objects stay sharp
            let ids = Set(layers.map(\.id))
            let l2 = find(ids, in: st2x.layers, order: layers.map(\.id))
            if l2.count == layers.count {
                let sp2 = CanvasSpace(width: st2x.width, height: st2x.height)
                let r2 = IRect(x: ob.x * 2, y: ob.y * 2, width: ob.width * 2, height: ob.height * 2)
                let b2 = RenderEngine.renderBuffer(appearance(l2, in: st2x), docRect: r2, space: sp2)
                if let d2 = encode(b2.makeCGImage()) { asset.name2x = "\(base)@2x.\(ext)"; asset.data2x = d2 }
            }
        }
        assets.append(asset)
        n.asset = asset
        return n
    }

    private func find(_ ids: Set<UUID>, in layers: [Layer], order: [UUID]) -> [Layer] {
        let all = layers.allLayers.filter { ids.contains($0.id) }
        return order.compactMap { id in all.first { $0.id == id } }
    }

    static func isOpaque(_ b: PixelBuffer) -> Bool {
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<b.height {
            let row = p + y * b.bytesPerRow
            for x in 0..<b.width where row[x * 4 + 3] != 255 { return false }
        }
        return true
    }

    // MARK: Semantics

    private func applySemantics(_ root: WebNode) {
        root.tag = "main"
        let texts = allNodes(root).filter { $0.kind == .text }
        if !texts.isEmpty {
            // body size: the size that carries the most characters
            var weight: [Double: Int] = [:]
            for t in texts { weight[(t.fontSize * 2).rounded() / 2, default: 0] += max(1, t.textLength) }
            let bodySize = weight.max { $0.value < $1.value }?.key ?? 16
            let headingSizes = Array(Set(texts.filter { $0.fontSize >= bodySize * 1.2 && $0.textLength <= 140 }.map { ($0.fontSize * 2).rounded() / 2 })).sorted(by: >)
            var usedH1 = false
            for t in texts {
                let sz = (t.fontSize * 2).rounded() / 2
                guard let rank = headingSizes.firstIndex(of: sz), t.textLength <= 140 else { t.tag = "p"; continue }
                if rank == 0 && !usedH1 { t.tag = "h1"; usedH1 = true }
                else { t.tag = "h\(min(4, max(2, rank + 1)))" }
            }
            // a single text size everywhere: the largest / first one is still the page heading when it is short
            if headingSizes.isEmpty, texts.count > 1, let top = texts.max(by: { $0.fontSize < $1.fontSize }), top.fontSize > bodySize { top.tag = "h1" }
        }
        for n in allNodes(root) where n.kind == .container && n !== root {
            let name = n.name.lowercased()
            let words = Set(name.split(whereSeparator: { !$0.isLetter }).map(String.init))
            if words.contains("header") { n.tag = "header" }
            else if !words.isDisjoint(with: ["nav", "navbar", "navigation", "menu"]) { n.tag = "nav" }
            else if words.contains("footer") { n.tag = "footer" }
            else if !words.isDisjoint(with: ["section", "hero", "features", "pricing"]) { n.tag = "section" }
            else if !words.isDisjoint(with: ["article", "card", "post"]) { n.tag = "article" }
            else if words.contains("aside") || words.contains("sidebar") { n.tag = "aside" }
            else if !words.isDisjoint(with: ["button", "btn", "cta"]) && !n.children.contains(where: { $0.kind == .container }) {
                n.tag = "button"
                n.attributes.append(("type", "button"))
                for c in n.children where c.kind == .text || c.kind == .box { c.tag = "span" }   // phrasing content only
            }
        }
    }

    // MARK: Auto layout (flex) inference

    /// Row / column detection: children evenly spaced along one axis and aligned on the other become a flex container
    /// with `gap`. A bottom child that spans the whole group (a plate behind the content) becomes the container's own
    /// background, border and shadow, with padding.
    private func inferFlex(_ n: WebNode) {
        guard n.children.count >= 1, n.children.allSatisfy({ abs($0.rotation) < 0.01 }) else { return }
        var kids = n.children
        var plate: WebNode? = nil
        if kids.count >= 2, let first = kids.first, first.kind == .box, first.children.isEmpty {
            let others = kids.dropFirst().reduce(CGRect.null) { $0.union($1.frame) }
            if first.frame.insetBy(dx: -0.75, dy: -0.75).contains(others) && abs(first.frame.width - n.frame.width) < 1.5 && abs(first.frame.height - n.frame.height) < 1.5 {
                plate = first
                kids.removeFirst()
            }
        }
        guard !kids.isEmpty, plate != nil || kids.count >= 2 else { return }
        let tol = 1.5
        func equalGaps(_ v: [Double]) -> Double? {
            guard let f = v.first else { return 0 }
            return v.allSatisfy { abs($0 - f) <= tol && $0 >= -0.5 } ? v.reduce(0, +) / Double(v.count) : nil
        }
        var direction: String? = nil
        var gap = 0.0
        var alignItems = "flex-start"
        var ordered = kids
        if kids.count == 1 {
            direction = "row"
        } else {
            let byX = kids.sorted { $0.frame.minX < $1.frame.minX }
            let gx = zip(byX, byX.dropFirst()).map { Double($1.frame.minX - $0.frame.maxX) }
            let byY = kids.sorted { $0.frame.minY < $1.frame.minY }
            let gy = zip(byY, byY.dropFirst()).map { Double($1.frame.minY - $0.frame.maxY) }
            if let g = equalGaps(gx), let a = crossAlign(byX.map { ($0.frame.minY, $0.frame.midY, $0.frame.maxY) }, tol) {
                direction = "row"; gap = g; alignItems = a; ordered = byX
            } else if let g = equalGaps(gy), let a = crossAlign(byY.map { ($0.frame.minX, $0.frame.midX, $0.frame.maxX) }, tol) {
                direction = "column"; gap = g; alignItems = a; ordered = byY
            }
        }
        guard let dir = direction else { return }
        let content = ordered.reduce(CGRect.null) { $0.union($1.frame) }
        var box = n.frame
        var border = 0.0
        if let p = plate {
            box = p.frame
            border = p.borderWidth
            n.frame = p.frame
            // the plate's look moves onto the container
            n.decl = p.decl.filter { $0.0 != "opacity" && $0.0 != "mix-blend-mode" } + n.decl.filter { $0.0 != "isolation" }
            n.borderWidth = p.borderWidth
        }
        var flex: [(String, String)] = [("display", "flex")]
        if dir == "column" { flex.append(("flex-direction", "column")) }
        let padL = Double(content.minX - box.minX) - border, padR = Double(box.maxX - content.maxX) - border
        let padT = Double(content.minY - box.minY) - border, padB = Double(box.maxY - content.maxY) - border
        let mainStart = dir == "row" ? padL : padT, mainEnd = dir == "row" ? padR : padB
        let crossStart = dir == "row" ? padT : padL, crossEnd = dir == "row" ? padB : padR
        var justify = "flex-start"
        if abs(mainStart - mainEnd) <= tol && mainStart > tol { justify = "center" }
        // a single child (or a row) centred on the cross axis inside a plate
        if kids.count == 1 || alignItems == "center" {
            alignItems = abs(crossStart - crossEnd) <= tol ? "center" : (kids.count == 1 ? "flex-start" : alignItems)
        }
        if justify != "flex-start" { flex.append(("justify-content", justify)) }
        flex.append(("align-items", alignItems))
        if kids.count > 1 && gap > 0.01 { flex.append(("gap", len(gap))) }
        var pad = [max(0, padT), max(0, padR), max(0, padB), max(0, padL)]
        if justify == "center" { if dir == "row" { pad[1] = 0; pad[3] = 0 } else { pad[0] = 0; pad[2] = 0 } }
        if alignItems == "center" { if dir == "row" { pad[0] = 0; pad[2] = 0 } else { pad[1] = 0; pad[3] = 0 } }
        if pad.contains(where: { $0 > 0.01 }) { flex.append(("padding", pad.map { len($0) }.joined(separator: " "))) }
        n.flex = flex
        n.children = ordered
        for c in ordered { c.inFlow = true }
    }

    private func crossAlign(_ v: [(CGFloat, CGFloat, CGFloat)], _ tol: Double) -> String? {
        func same(_ xs: [CGFloat]) -> Bool { guard let f = xs.first else { return true }; return xs.allSatisfy { abs(Double($0 - f)) <= tol } }
        if same(v.map { $0.1 }) { return "center" }
        if same(v.map { $0.0 }) { return "flex-start" }
        if same(v.map { $0.2 }) { return "flex-end" }
        return nil
    }

    // MARK: CSS rules and markup

    /// Declarations of a node's rule (geometry relative to its parent container).
    func rule(for n: WebNode, parent: WebNode?) -> [(String, String)] {
        var d: [(String, String)] = []
        let origin = parent.map { CGPoint(x: Double($0.frame.minX) + $0.borderWidth, y: Double($0.frame.minY) + $0.borderWidth) } ?? .zero
        if n.inFlow {
            d.append(("position", "relative"))
            d.append(("flex", "none"))
        } else {
            d.append(("position", "absolute"))
            d.append(("left", len(n.frame.minX - origin.x)))
            d.append(("top", len(n.frame.minY - origin.y)))
        }
        d.append(("width", len(n.frame.width)))
        d.append(("height", len(n.frame.height)))
        if let f = n.flex { d += f }
        if abs(n.rotation) > 0.01 { d.append(("transform", "rotate(\(Self.num(n.rotation, 3))deg)")) }
        d += n.decl
        return d
    }

    private func emit(_ n: WebNode, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let attrs = n.attributes.map { " \($0.0)=\"\(Self.escapeAttr($0.1))\"" }.joined()
        switch n.kind {
        case .container:
            out += "\(pad)<\(n.tag) class=\"\(n.cls)\"\(attrs)>\n"
            for c in n.children { emit(c, indent: indent + 1, into: &out) }
            out += "\(pad)</\(n.tag)>\n"
        case .box:
            out += "\(pad)<\(n.tag) class=\"\(n.cls)\"></\(n.tag)>\n"
        case .text:
            out += "\(pad)<\(n.tag) class=\"\(n.cls)\">\(n.inner)</\(n.tag)>\n"
        case .svg:
            out += "\(pad)<svg class=\"\(n.cls)\" \(n.inner.dropFirst(5))\n"
        case .image:
            guard let a = n.asset else { return }
            var src = "assets/\(a.name)"
            var srcset: String? = a.name2x.map { "assets/\(a.name) 1x, assets/\($0) 2x" }
            if opt.singleFile {
                src = "data:\(a.mime);base64,\(a.data.base64EncodedString())"
                srcset = a.data2x.map { "\(src) 1x, data:\(a.mime);base64,\($0.base64EncodedString()) 2x" }
            }
            out += "\(pad)<img class=\"\(n.cls)\" src=\"\(src)\""
            if let s = srcset { out += " srcset=\"\(s)\"" }
            out += " width=\"\(a.width)\" height=\"\(a.height)\" alt=\"\(Self.escapeAttr(n.alt))\" />\n"
        }
    }
}

// MARK: - SVG

enum LayerSVGExport {
    /// SVG path data for a CGPath, translated by `-origin`.
    static func pathData(_ path: CGPath, origin: CGPoint = .zero) -> String {
        var d = ""
        func p(_ pt: CGPoint) -> String { "\(HTMLExportBuilder.num(Double(pt.x - origin.x))) \(HTMLExportBuilder.num(Double(pt.y - origin.y)))" }
        path.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint: d += "M\(p(el.points[0]))"
            case .addLineToPoint: d += "L\(p(el.points[0]))"
            case .addQuadCurveToPoint: d += "Q\(p(el.points[0])) \(p(el.points[1]))"
            case .addCurveToPoint: d += "C\(p(el.points[0])) \(p(el.points[1])) \(p(el.points[2]))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    /// `<svg …>…</svg>` for a shape. `viewBox` is in document space. `color` formats colours (tokens for the HTML
    /// exporter, plain literals for stand-alone SVG).
    static func markup(for s: ShapeContent, viewBox b: CGRect, idPrefix: String = "g", standalone: Bool = true, color: (RGBA) -> String = { HTMLExportBuilder.cssColor($0) }) -> String {
        func num(_ v: Double, _ digits: Int = 2) -> String { HTMLExportBuilder.num(v, digits) }
        let (path, evenOdd) = s.path.resolved
        let pb = s.path.bounds
        let d = pathData(path, origin: b.origin)
        var defs = ""
        func paint(_ p: PaintStyle, _ id: String) -> String {
            switch p {
            case .none, .pattern: return "none"
            case .color(let c): return color(c)
            case .gradient(let gf):
                let (s0, e0) = gf.endpoints(in: pb)
                let grad = gf.reverse ? gf.gradient.reversed() : gf.gradient
                let stops = grad.sortedStops.map { st -> String in
                    let lit = HTMLExportBuilder.cssColor(st.color.withAlpha(1))
                    return "<stop offset=\"\(num(st.location * 100, 2))%\" stop-color=\"\(lit)\"\(st.color.a < 0.999 ? " stop-opacity=\"\(num(st.color.a, 3))\"" : "") />"
                }.joined()
                if gf.type == .radial {
                    defs += "<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(num(Double(s0.x - b.minX)))\" cy=\"\(num(Double(s0.y - b.minY)))\" r=\"\(num(Double(s0.distance(to: e0))))\">\(stops)</radialGradient>"
                } else {
                    defs += "<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(num(Double(s0.x - b.minX)))\" y1=\"\(num(Double(s0.y - b.minY)))\" x2=\"\(num(Double(e0.x - b.minX)))\" y2=\"\(num(Double(e0.y - b.minY)))\">\(stops)</linearGradient>"
                }
                return "url(#\(id))"
            }
        }
        let fill = paint(s.fill, idPrefix + "f")
        var body = ""
        let rule = evenOdd ? " fill-rule=\"evenodd\"" : ""
        let hasStroke = !s.stroke.paint.isNone && s.stroke.width > 0
        if hasStroke {
            let sp = paint(s.stroke.paint, idPrefix + "s")
            var w = s.stroke.width
            var extra = ""
            if s.stroke.alignment != .center { w *= 2 }
            var attrs = " stroke=\"\(sp)\" stroke-width=\"\(num(w))\""
            if s.stroke.cap != .butt { attrs += " stroke-linecap=\"\(s.stroke.cap.rawValue)\"" }
            if s.stroke.join != .miter { attrs += " stroke-linejoin=\"\(s.stroke.join.rawValue)\"" }
            if !s.stroke.dash.isEmpty { attrs += " stroke-dasharray=\"\(s.stroke.dash.map { num($0 * s.stroke.width) }.joined(separator: " "))\"" }
            switch s.stroke.alignment {
            case .center:
                body = "<path d=\"\(d)\" fill=\"\(fill)\"\(rule)\(attrs) />"
            case .inside:
                defs += "<clipPath id=\"\(idPrefix)c\"><path d=\"\(d)\"\(evenOdd ? " clip-rule=\"evenodd\"" : "") /></clipPath>"
                extra = " clip-path=\"url(#\(idPrefix)c)\""
                body = "<path d=\"\(d)\" fill=\"\(fill)\"\(rule)\(attrs)\(extra) />"
            case .outside:
                // the doubled stroke is painted first, the fill covers its inner half
                body = "<path d=\"\(d)\" fill=\"none\"\(attrs) /><path d=\"\(d)\" fill=\"\(fill == "none" ? "none" : fill)\"\(rule) />"
                if fill == "none" {
                    defs += "<mask id=\"\(idPrefix)m\"><rect width=\"100%\" height=\"100%\" fill=\"#fff\" /><path d=\"\(d)\" fill=\"#000\"\(rule) /></mask>"
                    body = "<path d=\"\(d)\" fill=\"none\"\(attrs) mask=\"url(#\(idPrefix)m)\" />"
                }
            }
        } else {
            body = "<path d=\"\(d)\" fill=\"\(fill)\"\(rule) />"
        }
        let head = standalone
            ? "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(num(Double(b.width)))\" height=\"\(num(Double(b.height)))\" viewBox=\"0 0 \(num(Double(b.width))) \(num(Double(b.height)))\">"
            : "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(num(Double(b.width))) \(num(Double(b.height)))\" aria-hidden=\"true\">"
        return head + (defs.isEmpty ? "" : "<defs>\(defs)</defs>") + body + "</svg>"
    }

    /// Stand-alone SVG for a shape.
    static func svg(for s: ShapeContent, name: String = "") -> String {
        let b = ShapeRenderer.docBounds(s).insetBy(dx: 2, dy: 2).integral.insetBy(dx: -1, dy: -1)
        return markup(for: s, viewBox: b)
    }

    /// "Copy as SVG" for a vector layer: shapes as paths, text as outlines, groups of those combined.
    static func svg(for layer: Layer, in st: DocumentState) -> String? {
        var shapes: [(ShapeContent, Double)] = []
        func collect(_ l: Layer, _ opacity: Double) {
            guard l.isVisible else { return }
            switch l.content {
            case .shape(let s): shapes.append((s, opacity * l.opacity))
            case .text(let t):
                let vp = VectorPath.from(cgPath: TextRenderer.outlinePath(t))
                shapes.append((ShapeContent(geometry: .path(vp), fill: .color(t.color)), opacity * l.opacity))
            case .group(let g): for c in g.children { collect(c, opacity * l.opacity) }
            default: break
            }
        }
        collect(layer, 1)
        guard !shapes.isEmpty else { return nil }
        if shapes.count == 1, shapes[0].1 >= 0.999 { return svg(for: shapes[0].0) }
        let b = shapes.reduce(CGRect.null) { $0.union(ShapeRenderer.docBounds($1.0).insetBy(dx: 2, dy: 2)) }.integral.insetBy(dx: -1, dy: -1)
        func num(_ v: Double, _ digits: Int = 2) -> String { HTMLExportBuilder.num(v, digits) }
        let bw = num(Double(b.width)), bh = num(Double(b.height))
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(bw)\" height=\"\(bh)\" viewBox=\"0 0 \(bw) \(bh)\">"
        for (i, pair) in shapes.enumerated() {
            let inner = markup(for: pair.0, viewBox: b, idPrefix: "g\(i)")
            // strip the wrapper of the nested markup
            guard let a = inner.firstIndex(of: ">"), let z = inner.range(of: "</svg>", options: .backwards) else { continue }
            let body = String(inner[inner.index(after: a)..<z.lowerBound])
            let op: String = pair.1 < 0.999 ? " opacity=\"" + num(pair.1, 3) + "\"" : ""
            out += "<g" + op + ">" + body + "</g>"
        }
        return out + "</svg>"
    }
}
