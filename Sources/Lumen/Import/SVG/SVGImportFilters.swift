import AppKit
import ImageIO
import ImageCratCore

// SVG import, part 7: filters that map to a layer effect (drop shadows), and `<image>` sources.

enum SVGImportFilters {
    /// What a filter primitive's result is, as far as drop shadows are concerned.
    private indirect enum Sym {
        case transparent
        case source
        /// A copy of the element's alpha: offset, blurred, tinted.
        case shadow(dx: Double, dy: Double, sigma: Double, color: RGBA, alpha: Double, knockout: Bool)
        /// The element's alpha minus an offset, blurred copy of it: an inner shadow.
        case inner(dx: Double, dy: Double, sigma: Double, color: RGBA, alpha: Double)
        case flood(RGBA)
        case stack([Sym])      // bottom first
    }

    struct Shadows {
        /// Bottom first.
        var drop: [ShadowEffect] = []
        var inner: [ShadowEffect] = []
    }

    /// Drop and inner shadows when the filter is nothing but shadows around the unchanged element; nil otherwise.
    /// `value` is the `filter` property: `url(#id)` or CSS `drop-shadow(…)` functions.
    static func shadows(_ value: String, doc: SVGImportDocument, ctx: SVGImportBuilder.Context, bbox: CGRect?) -> Shadows? {
        let ctm = ctx.ctm
        // blur radii and offsets are in user units: a distorted space has no layer-effect equivalent
        guard ctm.isSimilarity else { return nil }
        let scale = Double(ctm.meanScale)
        func effect(dx: Double, dy: Double, sigma: Double, color: RGBA, alpha: Double, knockout: Bool) -> ShadowEffect {
            let off = CGPoint(x: dx, y: dy).applying(CGAffineTransform(a: ctm.a, b: ctm.b, c: ctm.c, d: ctm.d, tx: 0, ty: 0))
            var s = ShadowEffect()
            s.enabled = true
            s.blendMode = .normal
            s.color = color.withAlpha(1)
            s.opacity = clamp(color.a * alpha, 0, 1)
            s.distance = Double(off.length)
            // EffectsRenderer moves the shadow by (−cos a, +sin a)·distance in document space
            s.angle = off.length > 1e-9 ? atan2(Double(off.y), -Double(off.x)) * 180 / .pi : 0
            s.spread = 0
            s.size = sigma * scale * 2.2        // the renderer blurs with sigma = size / 2.2
            s.useGlobalLight = false
            s.layerKnocksOut = knockout
            return s
        }
        let v = value.trimmingCharacters(in: .whitespaces)
        if !v.lowercased().hasPrefix("url(") {
            // CSS filter functions: only a list of drop-shadow()
            var out: [ShadowEffect] = []
            var rest = Substring(v)
            while !rest.isEmpty {
                rest = rest.drop { $0 == " " }
                guard rest.lowercased().hasPrefix("drop-shadow("), let close = matchingParen(rest, from: rest.index(rest.startIndex, offsetBy: 11)) else { return nil }
                let inner = String(rest[rest.index(rest.startIndex, offsetBy: 12)..<close])
                rest = rest[rest.index(after: close)...]
                var lengths: [Double] = []
                var color = ctx.style.color
                for tok in SVGImportCSS.splitTopLevel(inner, " ") where !tok.isEmpty {
                    if let l = SVGImportValue.length(tok), l.unit != .percent { lengths.append(l.resolve(percentOf: 0, fontSize: ctx.style.fontSize)) }
                    else if let c = SVGImportValue.color(tok) { color = c }
                    else if tok.lowercased() != "currentcolor" { return nil }
                }
                guard lengths.count >= 2 else { return nil }
                out.append(effect(dx: lengths[0], dy: lengths[1], sigma: lengths.count > 2 ? lengths[2] : 0, color: color, alpha: 1, knockout: false))
            }
            return out.isEmpty ? nil : Shadows(drop: out)
        }
        guard let f = doc.target(v), f.tag == "filter" else { return nil }
        if (f.attrs["primitiveUnits"] ?? "userSpaceOnUse") == "objectBoundingBox" { return nil }
        let linear = (f.decls["color-interpolation-filters"] ?? "linearRGB").lowercased() != "srgb"
        func toSRGB(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        var results: [String: Sym] = [:]
        var last: Sym = .source
        var first = true
        func input(_ name: String?) -> Sym? {
            guard let name, !name.isEmpty else { return first ? .source : last }
            switch name {
            case "SourceGraphic": return .source
            case "SourceAlpha": return .shadow(dx: 0, dy: 0, sigma: 0, color: .black, alpha: 1, knockout: false)
            case "BackgroundImage", "BackgroundAlpha", "FillPaint", "StrokePaint": return nil
            default: return results[name]
            }
        }
        func floodColor(_ n: SVGImportNode) -> RGBA {
            var c = n.decls["flood-color"].flatMap { SVGImportValue.color($0) } ?? .black
            c.a *= clamp(n.decls["flood-opacity"].flatMap { SVGImportValue.number($0) } ?? 1, 0, 1)
            return c
        }
        for p in f.children where p.isSVG && !p.isText {
            // a primitive limited to a sub-region is more than a plain shadow
            if p.attrs["x"] != nil || p.attrs["y"] != nil || p.attrs["width"] != nil || p.attrs["height"] != nil {
                if p.tag != "feFlood" { return nil }
            }
            var out: Sym
            switch p.tag {
            case "feFlood":
                let c = floodColor(p)
                out = c.a <= 0 ? .transparent : .flood(c)
            case "feOffset":
                guard case .shadow(let dx, let dy, let s, let c, let a, let k)? = input(p.attrs["in"]) else { return nil }
                out = .shadow(dx: dx + (SVGImportValue.number(p.attrs["dx"]) ?? 0), dy: dy + (SVGImportValue.number(p.attrs["dy"]) ?? 0), sigma: s, color: c, alpha: a, knockout: k)
            case "feGaussianBlur":
                guard case .shadow(let dx, let dy, let s, let c, let a, let k)? = input(p.attrs["in"]) else { return nil }
                let sd = SVGImportValue.numbers(p.attrs["stdDeviation"])
                guard sd.count <= 2, sd.allSatisfy({ $0 >= 0 }), sd.count < 2 || abs(sd[0] - sd[1]) < 1e-6 else { return nil }
                let add = sd.first ?? 0
                out = .shadow(dx: dx, dy: dy, sigma: (s * s + add * add).squareRoot(), color: c, alpha: a, knockout: k)
            case "feColorMatrix":
                guard (p.attrs["type"] ?? "matrix") == "matrix" else { return nil }
                let m = SVGImportValue.numbers(p.attrs["values"])
                guard m.count == 20 else { return nil }
                if case .inner(let dx, let dy, let s, _, let a)? = input(p.attrs["in"]) {
                    for r in 0..<3 { for c in 0..<4 where abs(m[r * 5 + c]) > 1e-6 { return nil } }
                    guard abs(m[15]) < 1e-6, abs(m[16]) < 1e-6, abs(m[17]) < 1e-6, abs(m[19]) < 1e-6, m[18] >= 0, m[18] <= 1 else { return nil }
                    var col = RGBA(r: clamp(m[4], 0, 1), g: clamp(m[9], 0, 1), b: clamp(m[14], 0, 1))
                    if linear { col = RGBA(r: toSRGB(col.r), g: toSRGB(col.g), b: toSRGB(col.b)) }
                    out = .inner(dx: dx, dy: dy, sigma: s, color: col, alpha: a * m[18])
                    break
                }
                guard case .shadow(let dx, let dy, let s, _, let a, let k)? = input(p.attrs["in"]) else { return nil }
                // colour rows must be constants, the alpha row a multiple of alpha
                for r in 0..<3 { for c in 0..<4 where abs(m[r * 5 + c]) > 1e-6 { return nil } }
                guard abs(m[15]) < 1e-6, abs(m[16]) < 1e-6, abs(m[17]) < 1e-6, abs(m[19]) < 1e-6, m[18] >= 0 else { return nil }
                var col = RGBA(r: clamp(m[4], 0, 1), g: clamp(m[9], 0, 1), b: clamp(m[14], 0, 1))
                if linear { col = RGBA(r: toSRGB(col.r), g: toSRGB(col.g), b: toSRGB(col.b)) }
                // "hard alpha" (× 127): every covered pixel becomes opaque, which for antialiased shapes is the alpha itself
                out = .shadow(dx: dx, dy: dy, sigma: s, color: col, alpha: m[18] > 1 ? (s > 0 ? 1 : a) : a * m[18], knockout: k)
                if m[18] > 1, s > 0 { return nil }
            case "feComponentTransfer":
                guard case .shadow(let dx, let dy, let s, let c, let a, let k)? = input(p.attrs["in"]) else { return nil }
                var mul = 1.0
                for fn in p.children where fn.isSVG && !fn.isText {
                    guard fn.tag == "feFuncA", (fn.attrs["type"] ?? "") == "linear", (SVGImportValue.number(fn.attrs["intercept"]) ?? 0) == 0 else { return nil }
                    mul = SVGImportValue.number(fn.attrs["slope"]) ?? 1
                }
                guard mul >= 0, mul <= 1 else { return nil }
                out = .shadow(dx: dx, dy: dy, sigma: s, color: c, alpha: a * mul, knockout: k)
            case "feComposite":
                let op = (p.attrs["operator"] ?? "over").lowercased()
                guard let a = input(p.attrs["in"]), let b = input(p.attrs["in2"]) else { return nil }
                switch (op, a, b) {
                case ("in", .flood(let col), .shadow(let dx, let dy, let s, _, let al, let k)):
                    out = .shadow(dx: dx, dy: dy, sigma: s, color: col.withAlpha(1), alpha: al * col.a, knockout: k)
                case ("out", .shadow(let dx, let dy, let s, let c, let al, _), .shadow(let dx2, let dy2, let s2, _, _, _)) where dx2 == 0 && dy2 == 0 && s2 == 0:
                    out = .shadow(dx: dx, dy: dy, sigma: s, color: c, alpha: al, knockout: true)
                case ("arithmetic", .shadow(let dx, let dy, let s, _, _, _), .shadow(let dx2, let dy2, let s2, _, _, _)) where dx2 == 0 && dy2 == 0 && s2 == 0:
                    // alpha − shifted alpha (k2 = −1, k3 = 1): what is left is the inner rim
                    func k(_ name: String) -> Double { SVGImportValue.number(p.attrs[name]) ?? 0 }
                    guard k("k1") == 0, k("k2") == -1, k("k3") == 1, k("k4") == 0 else { return nil }
                    out = .inner(dx: dx, dy: dy, sigma: s, color: .black, alpha: 1)
                case ("over", _, _):
                    out = .stack(flatten(b) + flatten(a))
                default: return nil
                }
            case "feBlend":
                guard (p.attrs["mode"] ?? "normal").lowercased() == "normal", let a = input(p.attrs["in"]), let b = input(p.attrs["in2"]) else { return nil }
                out = .stack(flatten(b) + flatten(a))
            case "feMerge":
                var list: [Sym] = []
                for node in p.children where node.isSVG && node.tag == "feMergeNode" {
                    guard let s = input(node.attrs["in"]) else { return nil }
                    list += flatten(s)
                }
                out = .stack(list)
            case "feDropShadow":
                guard case .source? = input(p.attrs["in"]) else { return nil }
                let sd = SVGImportValue.numbers(p.attrs["stdDeviation"])
                guard sd.count <= 2, sd.count < 2 || abs(sd[0] - sd[1]) < 1e-6 else { return nil }
                let c = floodColor(p)
                out = .stack([.shadow(dx: SVGImportValue.number(p.attrs["dx"]) ?? 2, dy: SVGImportValue.number(p.attrs["dy"]) ?? 2, sigma: sd.first ?? 2,
                                      color: c.withAlpha(1), alpha: c.a, knockout: false), .source])
            default:
                return nil
            }
            if let r = p.attrs["result"], !r.isEmpty { results[r] = out }
            last = out
            first = false
        }
        // the final result: drop shadows, the element itself, inner shadows on top
        let layers = flatten(last).filter { if case .transparent = $0 { return false }; return true }
        var out = Shadows()
        var seenSource = false
        for l in layers {
            switch l {
            case .source:
                if seenSource { return nil }
                seenSource = true
            case .shadow(let dx, let dy, let s, let c, let a, let k):
                if seenSource { return nil }
                out.drop.append(effect(dx: dx, dy: dy, sigma: s, color: c, alpha: a, knockout: k))
            case .inner(let dx, let dy, let s, let c, let a):
                if !seenSource { return nil }
                out.inner.append(effect(dx: dx, dy: dy, sigma: s, color: c, alpha: a, knockout: false))
            default: return nil
            }
        }
        // an unfiltered element has no business here
        guard seenSource, !(out.drop.isEmpty && out.inner.isEmpty), out.drop.count <= 6, out.inner.count <= 6 else { return nil }
        return out
    }

    private static func flatten(_ s: Sym) -> [Sym] {
        if case .stack(let l) = s { return l.flatMap(flatten) }
        return [s]
    }

    private static func matchingParen(_ s: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var i = open
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    /// Short description for the report ("filter (feGaussianBlur, feTurbulence)").
    static func describe(_ value: String, doc: SVGImportDocument) -> String {
        guard let f = doc.target(value), f.tag == "filter" else { return "CSS filter" }
        var names: [String] = []
        for p in f.children where p.isSVG && !p.isText && !names.contains(p.tag) { names.append(p.tag) }
        return names.isEmpty ? "filter" : "filter (\(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? ", …" : ""))"
    }
}

// MARK: - Images

enum SVGImportImages {
    enum Loaded {
        case pixels(PixelBuffer)
        case document(DocumentState)
        var size: CGSize {
            switch self {
            case .pixels(let b): return CGSize(width: b.width, height: b.height)
            case .document(let d): return CGSize(width: d.width, height: d.height)
            }
        }
    }

    static func isRemote(_ href: String) -> Bool {
        let l = href.lowercased()
        return l.hasPrefix("http:") || l.hasPrefix("https:") || l.hasPrefix("ftp:") || l.hasPrefix("//")
    }

    /// Bytes behind an image reference: a `data:` URI, or a file below the SVG's own folder. Nothing else is read —
    /// no network, no absolute paths, no `..` out of the folder.
    static func data(_ href: String, doc: SVGImportDocument) -> (Data, String)? {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.lowercased().hasPrefix("data:") {
            guard let comma = h.firstIndex(of: ",") else { return nil }
            let header = h[h.index(h.startIndex, offsetBy: 5)..<comma].lowercased()
            let payload = String(h[h.index(after: comma)...])
            let mime = header.split(separator: ";").first.map(String.init) ?? ""
            if header.contains(";base64") {
                let cleaned = payload.filter { !$0.isWhitespace }
                guard let d = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters), !d.isEmpty else { return nil }
                return (d, mime)
            }
            guard let text = payload.removingPercentEncoding else { return nil }
            return (Data(text.utf8), mime)
        }
        guard !isRemote(h), let base = doc.baseURL, !h.hasPrefix("/"), !h.lowercased().hasPrefix("file:"), !h.contains(":") else { return nil }
        let rel = h.removingPercentEncoding ?? h
        let url = base.appendingPathComponent(rel).standardizedFileURL
        let root = base.standardizedFileURL.path
        guard url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size < 200 << 20, let d = try? Data(contentsOf: url) else { return nil }
        return (d, url.pathExtension.lowercased() == "svg" ? "image/svg+xml" : "")
    }

    static func load(_ href: String, doc: SVGImportDocument, depth: Int) -> Loaded? {
        guard let (d, mime) = data(href, doc: doc) else { return nil }
        let looksSVG = mime.contains("svg") || d.prefix(256).range(of: Data("<svg".utf8)) != nil || d.prefix(5) == Data("<?xml".utf8)
        if looksSVG {
            guard depth < 3 else { return nil }
            var s = SVGImportSettings()
            s.nesting = depth + 1
            s.minimumSide = 0
            guard let r = try? SVGImport.load(data: d, baseURL: doc.baseURL, name: "Image", settings: s) else { return nil }
            return .document(r.state)
        }
        guard let src = CGImageSourceCreateWithData(d as CFData, nil), CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              cg.width > 0, cg.height > 0, cg.width <= 30000, cg.height <= 30000, cg.width * cg.height <= 400_000_000 else { return nil }
        return .pixels(PixelBuffer(cgImage: cg))
    }

    /// `data:` URI for an image reference (the raster fallback cannot read files), or nil when it is not loadable.
    static func inlined(_ href: String, doc: SVGImportDocument) -> String? {
        if href.lowercased().hasPrefix("data:") { return href }
        guard let (d, mime) = data(href, doc: doc) else { return nil }
        var type = mime
        if type.isEmpty {
            let b = [UInt8](d.prefix(12))
            if b.starts(with: [0x89, 0x50]) { type = "image/png" }
            else if b.starts(with: [0xFF, 0xD8]) { type = "image/jpeg" }
            else if b.starts(with: [0x47, 0x49, 0x46]) { type = "image/gif" }
            else if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { type = "image/webp" }
            else { type = "image/png" }
        }
        return "data:\(type);base64,\(d.base64EncodedString())"
    }
}
