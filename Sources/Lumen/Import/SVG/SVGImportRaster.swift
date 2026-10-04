import AppKit
import WebKit
import ImageCratCore

// SVG import, part 9: pixels for what cannot be layers.
//
// Each raster job is turned back into a small stand-alone SVG — the document's resources plus only the one element, in
// place — and rendered by the system: WebKit (as an `<img>`, so scripts and external resources are inert by design),
// or Core SVG when WebKit is not available (off the main thread, no web process). Masks are rendered the same way as
// the coverage of a white rectangle that has the element's bounding box.

final class SVGImportRaster {
    let doc: SVGImportDocument
    let natural: CGSize
    let size: (Int, Int)
    let useWebKit: Bool
    private var referenced: Set<String> = []
    private var holdsReferenced: Set<Int> = []
    private var inlineCache: [String: String?] = [:]
    /// Renderer that produced the last tiles ("WebKit" / "Core SVG"), for the report.
    private(set) var engine = ""

    init(doc: SVGImportDocument, natural: CGSize, size: (Int, Int), useWebKit: Bool) {
        self.doc = doc; self.natural = natural; self.size = size; self.useWebKit = useWebKit
    }

    // MARK: Jobs

    func renderWhole() -> (PixelBuffer, IPoint)? {
        guard let cg = render([whole()]).first ?? nil else { return nil }
        let buf = PixelBuffer(cgImage: cg)
        return (buf, .zero)
    }

    /// Fills the placeholders the builder left in `layers` and removes those that come out empty.
    func run(_ jobs: inout [SVGImportRasterJob], layers: inout [Layer], report: inout SVGImportReport) {
        let alive = Set(layers.flatMap { $0.allIDs })
        jobs = jobs.filter { alive.contains($0.layerID) }
        guard !jobs.isEmpty else { return }
        prepareReferences()
        var failed = 0
        // in chunks: every rendered tile is a bitmap of the whole document until it has been trimmed
        let chunk = max(1, min(64, 48_000_000 / max(1, size.0 * size.1)))
        var start = 0
        while start < jobs.count {
            let part = Array(jobs[start..<min(jobs.count, start + chunk)])
            start += part.count
            let svgs: [String] = part.map { job in
                switch job.kind {
                case .element: return element(job.node, baked: job.baked)
                case .mask(let id, let bbox, let local): return mask(job.node, id: id, bbox: bbox, local: local)
                }
            }
            if let dump = ProcessInfo.processInfo.environment["LUMEN_SVGIMPORT_DUMP"] {     // debugging aid: the stand-alone SVG of every job
                for (i, s) in svgs.enumerated() { try? s.write(toFile: dump + "/job-\(start - part.count + i).svg", atomically: true, encoding: .utf8) }
            }
            let images = render(svgs)
            for (job, img) in zip(part, images) {
                let name = layers.find(job.layerID)?.name ?? ""
                guard let cg = img else {
                    failed += 1
                    if case .element = job.kind { _ = Self.remove(job.layerID, from: &layers) }
                    continue
                }
                let full = PixelBuffer(cgImage: cg)
                switch job.kind {
                case .element:
                    guard let ob = full.opaqueBounds() else {
                        _ = Self.remove(job.layerID, from: &layers)
                        continue
                    }
                    let buf = ob == full.bounds ? full : full.cropped(to: ob)
                    layers.update(job.layerID) { $0.content = .raster(RasterContent(buffer: buf, origin: ob.origin)) }
                    report.rasterized += 1
                    report.note(.rasterized, "\(job.what.prefix(1).uppercased() + job.what.dropFirst())" + (name.isEmpty || name == "Path" || name == "Group" ? "" : " — “\(name)”"))
                case .mask:
                    // white under the mask: alpha is the mask's coverage
                    let gray = full.toGray(useAlpha: true)
                    if let ob = gray.opaqueBounds() {
                        let buf = ob == gray.bounds ? gray : gray.cropped(to: ob)
                        layers.update(job.layerID) { $0.mask = LayerMask(buffer: buf, origin: ob.origin, outsideValue: 0) }
                    } else {
                        layers.update(job.layerID) { $0.mask = LayerMask(buffer: PixelBuffer(width: 1, height: 1, gray: 0), origin: .zero, outsideValue: 0) }
                    }
                }
            }
        }
        if failed > 0 { report.note(.warning, "\(failed) element\(failed == 1 ? "" : "s") could not be rendered by the system and \(failed == 1 ? "was" : "were") left out.") }
        if engine == "Core SVG" { report.note(.warning, "WebKit was not available: rasterized elements were drawn by Core SVG, which ignores filters and some text features.") }
        jobs.removeAll()
    }

    /// Removes the placeholders without rendering anything (the stand-alone SVGs are still written out, so fuzzing
    /// covers the serializer).
    func drop(_ jobs: inout [SVGImportRasterJob], layers: inout [Layer]) {
        prepareReferences()
        for j in jobs {
            switch j.kind {
            case .element: _ = element(j.node, baked: j.baked); Self.remove(j.layerID, from: &layers)
            case .mask(let id, let bbox, let local): _ = mask(j.node, id: id, bbox: bbox, local: local)
            }
        }
        jobs.removeAll()
    }

    @discardableResult
    private static func remove(_ id: UUID, from layers: inout [Layer]) -> Bool {
        guard let p = layers.indexPath(of: id) else { return false }
        layers.remove(at: p)
        return true
    }

    // MARK: Rendering

    /// One image of the document size per SVG string (nil where rendering failed).
    func render(_ svgs: [String]) -> [CGImage?] {
        guard !svgs.isEmpty else { return [] }
        // WebKit needs the main thread (its run loop delivers the page); anywhere else Core SVG has to do
        if useWebKit, Thread.isMainThread {
            let out = SVGImportWebKit.render(svgs, width: size.0, height: size.1)
            if out.contains(where: { $0 != nil }) { engine = "WebKit"; return out }
        }
        engine = "Core SVG"
        return svgs.map { SVGImportRaster.coreSVG($0, width: size.0, height: size.1) }
    }

    /// AppKit's own SVG renderer (covers less of SVG than WebKit: no filters, limited text).
    static func coreSVG(_ svg: String, width: Int, height: Int) -> CGImage? {
        guard let img = NSImage(data: Data(svg.utf8)),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        img.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Serialization

    private static let resources: Set<String> = [
        "defs", "style", "linearGradient", "radialGradient", "pattern", "clipPath", "mask", "filter", "marker", "symbol", "font", "font-face", "color-profile",
    ]
    private static let dropped: Set<String> = ["script", "iframe", "object", "embed", "link", "meta", "base", "audio", "video", "form", "input", "button", "textarea", "select"]

    private func prepareReferences() {
        guard referenced.isEmpty else { return }
        func scan(_ v: String) {
            var rest = Substring(v)
            while let r = rest.range(of: "#") {
                var end = r.upperBound
                while end < rest.endIndex, !")\"' ;,".contains(rest[end]) { end = rest.index(after: end) }
                let id = String(rest[r.upperBound..<end])
                if !id.isEmpty { referenced.insert(id) }
                rest = rest[end...]
            }
        }
        var stack = [doc.root]
        while let n = stack.popLast() {
            for (k, v) in n.attrs where v.contains("#") && k != "id" { scan(v) }
            for (_, v) in n.decls where v.contains("#") { scan(v) }
            stack.append(contentsOf: n.children)
        }
        func mark(_ n: SVGImportNode, _ depth: Int) -> Bool {
            var has = n.id.map { referenced.contains($0) } ?? false
            if depth < 220 { for c in n.children where !c.isText { if mark(c, depth + 1) { has = true } } }
            if has { holdsReferenced.insert(n.index) }
            return has
        }
        _ = mark(doc.root, 0)
    }

    private static func escape(_ s: String, attribute: Bool) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += attribute ? "&quot;" : "\""
            case "\n" where attribute: out += "&#10;"
            case "\t" where attribute: out += "&#9;"
            default:
                // characters XML 1.0 cannot carry
                if u.value < 0x20 && u != "\n" && u != "\t" && u != "\r" { continue }
                if u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// `<tag attributes>` with `style` extended by `extra` and attributes replaced by `set` (nil removes).
    private func openTag(_ n: SVGImportNode, extra: String = "", set: [String: String?] = [:], inForeign: Bool) -> String {
        var s = "<" + n.tag
        var attrs = n.attrs
        for (k, v) in set { attrs[k] = v }
        if !extra.isEmpty {
            let old = attrs["style"].map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            attrs["style"] = old.isEmpty ? extra : (old.hasSuffix(";") ? old + extra : old + ";" + extra)
        }
        for k in attrs.keys.sorted() {
            guard var v = attrs[k] else { continue }
            let l = k.lowercased()
            if l.hasPrefix("on") { continue }                                  // event handlers
            if let c = k.firstIndex(of: ":") {
                let p = k[..<c]
                if p == "xmlns" { continue }
                if p != "xlink" && p != "xml" { continue }                     // editor namespaces (inkscape:, sodipodi:, …)
            } else if k == "xmlns", !inForeign { continue }
            if l == "href" || l == "xlink:href" {
                if n.tag == "image" || n.tag == "feImage" {
                    if v.hasPrefix("#") { /* element reference */ }
                    else {
                        if inlineCache[v] == nil { inlineCache[v] = .some(SVGImportImages.inlined(v, doc: doc)) }
                        guard let inl = inlineCache[v] ?? nil else { continue }
                        v = inl
                    }
                } else if !v.hasPrefix("#") { continue }                        // links and other documents
            }
            if !inForeign || l != "style" { if v.lowercased().contains("javascript:") { continue } }
            s += " \(k)=\"\(Self.escape(v, attribute: true))\""
        }
        return s + ">"
    }

    private func subtree(_ n: SVGImportNode, into out: inout String, inForeign: Bool, depth: Int, extra: String = "") {
        guard depth < 230 else { return }
        if n.isText { out += Self.escape(n.text, attribute: false); return }
        if Self.dropped.contains(n.tag.lowercased()) { return }
        var foreign = inForeign
        if !foreign && !n.isSVG { return }                                      // editor metadata elements
        var set: [String: String?] = [:]
        if foreign, !n.isSVG, n.attrs["xmlns"] == nil { set["xmlns"] = "http://www.w3.org/1999/xhtml" }
        out += openTag(n, extra: extra, set: set, inForeign: foreign)
        if n.tag == "foreignObject" { foreign = true }
        for c in n.children { subtree(c, into: &out, inForeign: foreign, depth: depth + 1) }
        out += "</\(n.tag)>"
    }

    private func num(_ v: CGFloat) -> String {
        guard v.isFinite else { return "0" }
        var s = String(format: "%.6f", Double(v))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// Wraps the (rewritten) root element so that it renders at the import size, however the root is sized itself.
    private func wrap(_ body: (inout String) -> Void) -> String {
        let t = SVGImport.fit(natural, size)
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(size.0)\" height=\"\(size.1)\">"
            + "<g transform=\"matrix(\(num(t.a)) 0 0 \(num(t.d)) \(num(t.tx)) \(num(t.ty)))\">"
        body(&s)
        return s + "</g></svg>"
    }

    private var rootSet: [String: String?] {
        ["width": num(natural.width), "height": num(natural.height), "x": nil, "y": nil]
    }

    private static let neutral = "opacity:1!important;filter:none!important;clip-path:none!important;mask:none!important;mix-blend-mode:normal!important"

    /// The whole document.
    func whole() -> String {
        wrap { s in
            s += openTag(doc.root, set: rootSet, inForeign: false)
            for c in doc.root.children { subtree(c, into: &s, inForeign: false, depth: 1) }
            s += "</svg>"
        }
    }

    /// Only `target` (and the resources it may reference), where it sits in the document.
    /// - replacement: markup emitted instead of the target (mask jobs).
    private func isolated(_ target: SVGImportNode, targetExtra: String, replacement: String? = nil) -> String {
        var path = Set<Int>()
        var a: SVGImportNode? = target.parent
        while let x = a { path.insert(x.index); a = x.parent }
        func emit(_ n: SVGImportNode, _ out: inout String, _ depth: Int) {
            guard depth < 230, !n.isText, n.isSVG else { return }
            if n === target {
                if let r = replacement { out += r } else { subtree(n, into: &out, inForeign: false, depth: depth, extra: targetExtra) }
            } else if path.contains(n.index) {
                out += openTag(n, extra: Self.neutral, set: n === doc.root ? rootSet : [:], inForeign: false)
                for c in n.children { emit(c, &out, depth + 1) }
                out += "</\(n.tag)>"
            } else if Self.resources.contains(n.tag) {
                subtree(n, into: &out, inForeign: false, depth: depth)
            } else if holdsReferenced.contains(n.index) {
                // drawn elsewhere, but something refers to it (or to something inside): keep it without drawing it
                out += "<defs>"
                subtree(n, into: &out, inForeign: false, depth: depth)
                out += "</defs>"
            }
        }
        return wrap { s in
            if target === doc.root {
                s += openTag(doc.root, extra: targetExtra, set: rootSet, inForeign: false)
                for c in doc.root.children { subtree(c, into: &s, inForeign: false, depth: 1) }
                s += "</svg>"
            } else {
                emit(doc.root, &s, 0)
            }
        }
    }

    func element(_ n: SVGImportNode, baked: Bool) -> String {
        prepareReferences()
        // opacity and blending are always layer properties
        let extra = baked ? "opacity:1!important;mix-blend-mode:normal!important" : Self.neutral
        return isolated(n, targetExtra: extra)
    }

    func mask(_ n: SVGImportNode, id: String, bbox: CGRect, local: CGAffineTransform) -> String {
        prepareReferences()
        // A white outline with the element's bounding box (so objectBoundingBox units resolve as for the element),
        // stroked so wide that it covers everything the mask may reveal; a stroke does not count towards the box.
        // Stroke only: WebKit applies a mask to fill and stroke separately, so overlapping the two would square it.
        let reach = max(natural.width, natural.height, bbox.width, bbox.height, abs(bbox.minX), abs(bbox.minY)) * 8 + 100
        let scale = max(1e-6, abs(local.determinant).squareRoot())
        var r = "<path d=\"M\(num(bbox.minX)) \(num(bbox.minY))H\(num(bbox.maxX))V\(num(bbox.maxY))H\(num(bbox.minX))Z\""
        r += " fill=\"none\" stroke=\"#fff\" stroke-linejoin=\"round\" stroke-width=\"\(num(reach / scale))\""
        r += " transform=\"matrix(\(num(local.a)) \(num(local.b)) \(num(local.c)) \(num(local.d)) \(num(local.tx)) \(num(local.ty)))\""
        r += " mask=\"url(#\(Self.escape(id, attribute: true)))\" style=\"opacity:1!important;filter:none!important;clip-path:none!important;mix-blend-mode:normal!important\"/>"
        return isolated(n, targetExtra: "", replacement: r)
    }
}

// MARK: - WebKit

/// Renders SVG strings offscreen. Each SVG is an `<img>`: WebKit then runs no scripts and loads no external resources
/// for it, whatever the file says.
enum SVGImportWebKit {
    private final class Job: NSObject, WKNavigationDelegate {
        let web: WKWebView
        let window: NSWindow
        var loaded = false
        var failed = false

        init(size: CGSize) {
            let cfg = WKWebViewConfiguration()
            cfg.suppressesIncrementalRendering = true
            cfg.websiteDataStore = .nonPersistent()
            cfg.defaultWebpagePreferences.allowsContentJavaScript = false
            web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
            web.setValue(false, forKey: "drawsBackground")
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            super.init()
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = web
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.orderFrontRegardless()
            web.navigationDelegate = self
        }

        func close() {
            web.navigationDelegate = nil
            web.stopLoading()
            window.orderOut(nil)
            window.contentView = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed = true }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true }
        // nothing may navigate away from the page we built
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let u = action.request.url?.absoluteString ?? ""
            decisionHandler(u == "about:blank" || u.isEmpty ? .allow : .cancel)
        }
    }

    /// Longest side WebKit is asked to lay out; larger documents are rendered smaller and scaled up.
    static let maxSide = 4096
    /// True once a render has timed out: later imports in this process skip WebKit instead of waiting again.
    private(set) static var unavailable = false
    static var timeout: TimeInterval = 20

    private static func spin(until done: () -> Bool, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > end { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return true
    }

    static func render(_ svgs: [String], width: Int, height: Int) -> [CGImage?] {
        guard !unavailable, width > 0, height > 0 else { return svgs.map { _ in nil } }
        // layout size (CSS px) of one tile
        let k = min(1, CGFloat(maxSide) / CGFloat(max(width, height)))
        let tw = max(1, (CGFloat(width) * k).rounded()), th = max(1, (CGFloat(height) * k).rounded())
        let perPage = max(1, Int(CGFloat(maxSide) / th))
        var out: [CGImage?] = []
        var i = 0
        while i < svgs.count {
            let batch = Array(svgs[i..<min(svgs.count, i + perPage)])
            i += batch.count
            out += page(batch, tile: CGSize(width: tw, height: th), pixels: (width, height))
            if unavailable { out += [CGImage?](repeating: nil, count: svgs.count - out.count); break }
        }
        return out
    }

    private static func page(_ svgs: [String], tile: CGSize, pixels: (Int, Int)) -> [CGImage?] {
        let none = [CGImage?](repeating: nil, count: svgs.count)
        var html = "<!doctype html><html><head><meta charset=\"utf-8\">"
        html += "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">"
        html += "<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}img{display:block;position:absolute;left:0;width:\(Int(tile.width))px;height:\(Int(tile.height))px}</style></head><body>"
        for (n, s) in svgs.enumerated() {
            html += "<img style=\"top:\(n * Int(tile.height))px\" src=\"data:image/svg+xml;base64,\(Data(s.utf8).base64EncodedString())\">"
        }
        html += "</body></html>"
        let pageSize = CGSize(width: tile.width, height: tile.height * CGFloat(svgs.count))
        let job = Job(size: pageSize)
        defer { job.close() }
        job.web.loadHTMLString(html, baseURL: nil)
        guard spin(until: { job.loaded || job.failed }, timeout: timeout), !job.failed else {
            if !job.failed { unavailable = true }
            return none
        }
        // images decode asynchronously: wait until every one has settled (also when it failed to decode)
        var settled = false
        var tries = 0
        while !settled && tries < 400 {
            var answered = false
            job.web.evaluateJavaScript("Array.prototype.every.call(document.images, function (i) { return i.complete; })", in: nil, in: .defaultClient) { r in
                if case .success(let v) = r, (v as? Bool) == true || (v as? NSNumber)?.boolValue == true { settled = true }
                answered = true
            }
            guard spin(until: { answered }, timeout: timeout) else { unavailable = true; return none }
            tries += 1
            if !settled { _ = spin(until: { false }, timeout: 0.02) }
        }
        // one more turn of the loop so the decoded images are painted
        _ = spin(until: { false }, timeout: 0.03)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(origin: .zero, size: pageSize)
        cfg.snapshotWidth = NSNumber(value: Double(pageSize.width))
        cfg.afterScreenUpdates = true
        var shot: NSImage? = nil
        var done = false
        job.web.takeSnapshot(with: cfg) { img, _ in shot = img; done = true }
        guard spin(until: { done }, timeout: timeout) else { unavailable = true; return none }
        guard let img = shot, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return none }
        // cut the page into tiles at the document's pixel size
        let sy = CGFloat(cg.height) / pageSize.height, sx = CGFloat(cg.width) / pageSize.width
        var out: [CGImage?] = []
        for n in 0..<svgs.count {
            let src = CGRect(x: 0, y: CGFloat(n) * tile.height * sy, width: tile.width * sx, height: tile.height * sy).integral
            guard let part = cg.cropping(to: src) else { out.append(nil); continue }
            out.append(resample(part, to: pixels))
        }
        return out
    }

    /// The snapshot at the document's pixel size. A Retina snapshot is a whole multiple: averaging the blocks keeps
    /// pixel-aligned edges exactly where they are (an interpolating filter would smear them into the neighbours).
    private static func resample(_ img: CGImage, to pixels: (Int, Int)) -> CGImage? {
        let (w, h) = pixels
        func context(_ w: Int, _ h: Int) -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let k = img.width / max(1, w)
        if k >= 1, img.width == w * k, img.height == h * k {
            guard let big = context(img.width, img.height) else { return nil }
            big.interpolationQuality = .none
            big.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            if k == 1 { return big.makeImage() }
            guard let small = context(w, h), let sp = big.data?.assumingMemoryBound(to: UInt8.self), let dp = small.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let srb = big.bytesPerRow, drb = small.bytesPerRow
            let n = UInt32(k * k), half = n / 2
            for y in 0..<h {
                for x in 0..<w {
                    var acc: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
                    for j in 0..<k {
                        let row = sp + (y * k + j) * srb + x * k * 4
                        for i in 0..<k {
                            acc.0 += UInt32(row[i * 4]); acc.1 += UInt32(row[i * 4 + 1]); acc.2 += UInt32(row[i * 4 + 2]); acc.3 += UInt32(row[i * 4 + 3])
                        }
                    }
                    let d = dp + y * drb + x * 4
                    d[0] = UInt8((acc.0 + half) / n); d[1] = UInt8((acc.1 + half) / n); d[2] = UInt8((acc.2 + half) / n); d[3] = UInt8((acc.3 + half) / n)
                }
            }
            return small.makeImage()
        }
        guard let ctx = context(w, h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
