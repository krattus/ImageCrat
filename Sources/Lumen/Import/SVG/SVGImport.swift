import AppKit
import CoreGraphics
import ImageCratCore

// SVG import: entry points, settings and the import report.
//
//   SVGImport.load(url:settings:)  →  DocumentState + SVGImportReport
//
// Pipeline: SVGImportXML (bytes → element tree with cascaded CSS) → SVGImportBuilder (elements → layers, raster jobs
// for what Lumen cannot represent) → SVGImportRaster (WebKit / Core SVG renders exactly those elements).

struct SVGImportSettings {
    enum Mode: String, CaseIterable, Identifiable {
        case editable = "Editable layers", flattened = "Flattened image"
        var id: String { rawValue }
    }
    /// Document size in pixels; nil = the SVG's own size (see `minimumSide`).
    var width: Int? = nil
    var height: Int? = nil
    var mode: Mode = .editable
    var whiteBackground = false
    /// `display: none` content arrives as hidden layers instead of being dropped.
    var includeHidden = true
    /// Default size only: artwork whose longest side is below this is opened at a whole multiple (icons are tiny at 1×).
    var minimumSide = 256
    /// Rasterize unsupported pieces with WebKit (false: Core SVG only).
    var useWebKit = true
    /// Depth of SVG images inside SVG images.
    var nesting = 0
    /// False leaves out whatever would have to be rasterized instead of rendering it (parser fuzzing).
    var rasterize = true
}

struct SVGImportReport: Codable, Equatable {
    enum Kind: String, Codable { case rasterized, substituted, ignored, warning }
    struct Item: Codable, Equatable {
        var kind: Kind
        var message: String
        var count = 1
    }
    var source = ""
    var naturalSize = ""
    var pixelSize = ""
    var flattened = false
    // what stayed editable
    var shapes = 0, texts = 0, groups = 0, images = 0, smartImages = 0
    var gradients = 0, shapedGradients = 0, clips = 0, masks = 0, vectorMasks = 0, effects = 0, blendModes = 0
    var outlinedTexts = 0, hidden = 0, invisible = 0
    var rasterized = 0
    var items: [Item] = []
    /// Fonts that are not installed → what was used instead.
    var missingFonts: [String: String] = [:]

    mutating func note(_ kind: Kind, _ message: String) {
        if let i = items.firstIndex(where: { $0.kind == kind && $0.message == message }) { items[i].count += 1; return }
        if items.count < 400 { items.append(Item(kind: kind, message: message)) }
    }

    var editableCount: Int { shapes + texts + images + smartImages }

    /// One line for the status bar.
    var summary: String {
        if flattened { return "Imported “\(source)” as a flattened image (\(pixelSize))." }
        var parts = ["\(editableCount) editable layer\(editableCount == 1 ? "" : "s")"]
        if rasterized > 0 { parts.append("\(rasterized) rasterized") }
        if !missingFonts.isEmpty { parts.append("\(missingFonts.count) font\(missingFonts.count == 1 ? "" : "s") substituted") }
        let ignored = items.filter { $0.kind == .ignored || $0.kind == .warning }.count
        if ignored > 0 { parts.append("\(ignored) note\(ignored == 1 ? "" : "s")") }
        return "Imported “\(source)”: " + parts.joined(separator: ", ") + "."
    }

    /// True when there is something worth pointing the user to.
    var hasFindings: Bool { rasterized > 0 || !missingFonts.isEmpty || !items.isEmpty || outlinedTexts > 0 }

    /// Plain-text report (the dialog and the self tests show this).
    var text: String {
        var l: [String] = []
        l.append("SVG import report — \(source)")
        l.append("Size: \(naturalSize) → \(pixelSize)")
        if flattened {
            l.append("Imported as a flattened image.")
        } else {
            l.append("")
            l.append("Kept editable")
            func row(_ n: Int, _ one: String, _ many: String) { if n > 0 { l.append("  \(n) \(n == 1 ? one : many)") } }
            row(shapes, "shape layer", "shape layers")
            row(texts, "text layer", "text layers")
            row(groups, "group", "groups")
            row(images, "pixel layer (image)", "pixel layers (images)")
            row(smartImages, "smart object (image)", "smart objects (images)")
            row(gradients, "gradient", "gradients")
            if shapedGradients > 0 { l.append("    (\(shapedGradients) with a placement beyond angle and scale — elliptical, skewed, off-centre, focal or repeating — kept exactly)") }
            row(clips, "clip path as vector mask", "clip paths as vector masks")
            row(vectorMasks, "mask as vector mask", "masks as vector masks")
            row(masks, "mask as layer mask", "masks as layer masks")
            row(effects, "filter as layer effect (drop shadow)", "filters as layer effects (drop shadow)")
            row(blendModes, "blend mode", "blend modes")
            row(hidden, "hidden element as a hidden layer", "hidden elements as hidden layers")
            if editableCount == 0 { l.append("  nothing") }
            if outlinedTexts > 0 { l.append(""); l.append("Converted"); l.append("  \(outlinedTexts) text element\(outlinedTexts == 1 ? "" : "s") to outline shapes (vector, no longer editable as text)") }
        }
        func section(_ title: String, _ kind: Kind) {
            let list = items.filter { $0.kind == kind }
            guard !list.isEmpty else { return }
            l.append(""); l.append(title)
            for it in list { l.append("  " + it.message + (it.count > 1 ? " ×\(it.count)" : "")) }
        }
        section("Rasterized (pixel layers at the import size)", .rasterized)
        section("Substituted", .substituted)
        if !missingFonts.isEmpty {
            l.append(""); l.append("Missing fonts")
            for (k, v) in missingFonts.sorted(by: { $0.key < $1.key }) { l.append("  “\(k)” is not installed — \(v) was used") }
        }
        section("Ignored", .ignored)
        section("Warnings", .warning)
        if invisible > 0 { l.append(""); l.append("\(invisible) element\(invisible == 1 ? "" : "s") without fill or stroke left out.") }
        return l.joined(separator: "\n")
    }
}

struct SVGImportResult {
    var state: DocumentState
    var report: SVGImportReport
}

enum SVGImport {
    static let maxSide = 16384
    /// More elements than this needing pixels of their own: the whole image is flattened instead.
    static let maxRasterJobs = 300

    // MARK: Size

    /// The SVG's own size in CSS pixels: width / height, else the viewBox, else the extent of the artwork.
    static func naturalSize(_ doc: SVGImportDocument) -> CGSize {
        let root = doc.root
        func abs(_ name: String) -> Double? {
            guard let l = SVGImportValue.length(root.attrs[name] ?? root.decls[name]), l.unit != .percent else { return nil }
            let v = l.resolve(percentOf: 0, fontSize: 16)
            return v > 0 && v.isFinite ? v : nil
        }
        var w = abs("width"), h = abs("height")
        let vb = SVGImportGeometry.viewBox(root)
        if let vb {
            if w == nil && h == nil { w = Double(vb.width); h = Double(vb.height) }
            else if w == nil { w = h! * Double(vb.width / vb.height) }
            else if h == nil { h = w! * Double(vb.height / vb.width) }
        }
        if w == nil || h == nil {
            // no size at all: whatever the artwork covers from the origin
            let ext = contentExtent(doc)
            if w == nil { w = ext.map { Double($0.maxX) } ?? 300 }
            if h == nil { h = ext.map { Double($0.maxY) } ?? 150 }
        }
        return CGSize(width: clamp(w ?? 300, 1e-3, 1e7), height: clamp(h ?? 150, 1e-3, 1e7))
    }

    /// Bounding box of the shapes (a quick pass without styles), for files that declare no size.
    private static func contentExtent(_ doc: SVGImportDocument) -> CGRect? {
        var box: CGRect? = nil
        var visited = 0
        func walk(_ n: SVGImportNode, _ t: CGAffineTransform, _ depth: Int) {
            guard depth < 64, visited < 50_000, n.isSVG, !n.isText else { return }
            visited += 1
            if ["defs", "symbol", "clipPath", "mask", "pattern", "marker", "linearGradient", "radialGradient", "filter", "style"].contains(n.tag) { return }
            let m = (SVGImportValue.transform(n.attrs["transform"]) ?? .identity).concatenating(t)
            if let s = SVGImportGeometry.shape(n, style: SVGImportStyle(), viewport: CGSize(width: 300, height: 150)) {
                var mm = m
                if let p = s.path.copy(using: &mm) {
                    let b = p.boundingBoxOfPath
                    if !b.isNull, b.maxX.isFinite, b.maxY.isFinite { box = box.map { $0.union(b) } ?? b }
                }
            }
            for c in n.children { walk(c, m, depth + 1) }
        }
        walk(doc.root, .identity, 0)
        guard let b = box, b.maxX > 0, b.maxY > 0 else { return nil }
        return CGRect(x: 0, y: 0, width: min(b.maxX, 1e5), height: min(b.maxY, 1e5))
    }

    /// Pixel size used when the settings name none: 1× (CSS px), or a whole multiple for tiny artwork.
    static func defaultPixelSize(_ natural: CGSize, minimumSide: Int = 256) -> (Int, Int) {
        var k = 1.0
        let longest = Double(max(natural.width, natural.height))
        if minimumSide > 0, longest < 100 { k = ceil(Double(minimumSide) / max(1, longest)) }
        var w = Double(natural.width) * k, h = Double(natural.height) * k
        let big = max(w, h)
        if big > Double(maxSide) { w *= Double(maxSide) / big; h *= Double(maxSide) / big }
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    /// Natural size → pixel size. A pixel size with the artwork's proportions (up to rounding to whole pixels) scales
    /// uniformly and centres, as a browser does; only a deliberately different aspect ratio stretches.
    static func fit(_ natural: CGSize, _ size: (Int, Int)) -> CGAffineTransform {
        let sx = CGFloat(size.0) / max(natural.width, 1e-6), sy = CGFloat(size.1) / max(natural.height, 1e-6)
        // proportional = one side is the other's scale applied and rounded to a whole pixel
        if abs(CGFloat(size.1) - natural.height * sx) <= 1.001 || abs(CGFloat(size.0) - natural.width * sy) <= 1.001 {
            let s = min(sx, sy)
            return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: (CGFloat(size.0) - natural.width * s) / 2, ty: (CGFloat(size.1) - natural.height * s) / 2)
        }
        return CGAffineTransform(scaleX: sx, y: sy)
    }

    // MARK: Loading

    static func load(url: URL, settings: SVGImportSettings = SVGImportSettings()) throws -> SVGImportResult {
        guard let data = try? Data(contentsOf: url) else { throw SVGImportError.unreadable }
        return try load(data: data, baseURL: url.deletingLastPathComponent(), name: url.lastPathComponent, settings: settings)
    }

    static func load(data: Data, baseURL: URL? = nil, name: String, settings: SVGImportSettings = SVGImportSettings()) throws -> SVGImportResult {
        let doc = try SVGImportXML.parse(data, baseURL: baseURL)
        return load(doc, name: name, settings: settings)
    }

    static func load(_ doc: SVGImportDocument, name: String, settings: SVGImportSettings) -> SVGImportResult {
        let natural = naturalSize(doc)
        var size = defaultPixelSize(natural, minimumSide: settings.minimumSide)
        if let w = settings.width, let h = settings.height { size = (w, h) }
        else if let w = settings.width { size = (w, max(1, Int((Double(w) * Double(natural.height / natural.width)).rounded()))) }
        else if let h = settings.height { size = (max(1, Int((Double(h) * Double(natural.width / natural.height)).rounded())), h) }
        size = (clamp(size.0, 1, maxSide), clamp(size.1, 1, maxSide))

        var st = DocumentState(width: size.0, height: size.1)
        // CSS pixels are 1/96 in: keep the physical size of the artwork
        st.resolution = clamp((96 * Double(size.0) / Double(natural.width) * 100).rounded() / 100, 1, 9600)
        let b = SVGImportBuilder(doc: doc, settings: settings, size: size, natural: natural)
        b.report.source = name
        b.report.naturalSize = "\(fmt(natural.width)) × \(fmt(natural.height)) px"
        b.report.pixelSize = "\(size.0) × \(size.1) px"
        let raster = SVGImportRaster(doc: doc, natural: natural, size: size, useWebKit: settings.useWebKit)

        var layers: [Layer] = []
        if settings.mode == .flattened {
            b.report.flattened = true
            if let (buf, origin) = raster.renderWhole() {
                layers = [Layer.raster(name: (name as NSString).deletingPathExtension.isEmpty ? "Layer 1" : (name as NSString).deletingPathExtension, buffer: buf, origin: origin)]
            } else {
                // no system renderer available: fall back to the layers we can build ourselves
                b.report.note(.warning, "The system SVG renderer was not available; the image was flattened from the imported layers.")
                layers = b.buildWithRoomToRecurse()
                raster.run(&b.jobs, layers: &layers, report: &b.report)
                st.layers = layers
                if let cg = Compositor.shared.flatten(st) { layers = [Layer.raster(name: "Layer 1", buffer: PixelBuffer(cgImage: cg))] }
            }
        } else {
            layers = b.buildWithRoomToRecurse()
            if settings.rasterize, b.jobs.count > maxRasterJobs, let (buf, origin) = raster.renderWhole() {
                // hundreds of pixel layers help nobody and take minutes to render one by one
                b.report.note(.warning, "\(b.jobs.count) elements would have had to be rasterized separately; the image was imported flattened instead.")
                b.report.flattened = true
                layers = [Layer.raster(name: "Layer 1", buffer: buf, origin: origin)]
            } else if settings.rasterize { raster.run(&b.jobs, layers: &layers, report: &b.report) }
            else { raster.drop(&b.jobs, layers: &layers) }
        }
        if settings.whiteBackground {
            let buf = PixelBuffer(width: size.0, height: size.1)
            buf.context.setFillColor(RGBA.white.cgColor)
            buf.context.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            buf.markDirty()
            layers.insert(Layer.raster(name: "Background", buffer: buf), at: 0)
        }
        if layers.isEmpty {
            // a document needs a layer to be usable
            layers = [Layer.raster(name: "Layer 1", width: size.0, height: size.1)]
            b.report.note(.warning, "The SVG draws nothing.")
        }
        st.layers = layers
        return SVGImportResult(state: st, report: b.report)
    }

    private static func fmt(_ v: CGFloat) -> String {
        let r = (Double(v) * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    /// True when `data` starts like an SVG document (pasteboard sniffing).
    static func looksLikeSVG(_ text: String) -> Bool {
        var s = Substring(text.prefix(4096))
        while true {
            s = s.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            if s.hasPrefix("<?xml") || s.hasPrefix("<!--") || s.lowercased().hasPrefix("<!doctype") {
                let end = s.hasPrefix("<?xml") ? "?>" : (s.hasPrefix("<!--") ? "-->" : ">")
                guard let r = s.range(of: end) else { return false }
                s = s[r.upperBound...]
                continue
            }
            break
        }
        return s.hasPrefix("<svg") && (s.dropFirst(4).first.map { $0.isWhitespace || $0 == ">" || $0 == "/" } ?? false)
    }
}
