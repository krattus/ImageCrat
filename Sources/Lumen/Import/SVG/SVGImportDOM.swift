import Foundation
import zlib

// SVG import, part 1: the file → an element tree with cascaded style declarations.
// The tree is plain data (no AppKit), so parsing can be fuzzed and run on any thread.

enum SVGImportError: LocalizedError {
    case unreadable, notSVG, tooLarge, damaged(String), cancelled
    var errorDescription: String? {
        switch self {
        case .unreadable: return "The SVG file could not be read."
        case .notSVG: return "The file does not contain an SVG image."
        case .tooLarge: return "The SVG file is too large to import."
        case .damaged(let s): return "The SVG file is damaged (\(s))."
        case .cancelled: return "The import was cancelled."
        }
    }
}

final class SVGImportNode {
    /// Local element name ("rect", "linearGradient"); "#text" for character data.
    let tag: String
    /// Namespace prefix of foreign elements ("inkscape", "sodipodi", "i"…); nil for SVG elements.
    let prefix: String?
    var attrs: [String: String]
    var children: [SVGImportNode] = []
    weak var parent: SVGImportNode?
    var text = ""
    /// Presentation properties after the cascade (attributes < style sheet < style attribute).
    var decls: [String: String] = [:]
    /// Document order (stable identity for the raster fallback and cycle guards).
    var index = 0

    init(tag: String, prefix: String?, attrs: [String: String]) {
        self.tag = tag; self.prefix = prefix; self.attrs = attrs
    }

    var isText: Bool { tag == "#text" }
    var isSVG: Bool { prefix == nil }
    var id: String? { attrs["id"].flatMap { $0.isEmpty ? nil : $0 } }
    /// href with or without the xlink prefix.
    var href: String? { attrs["href"] ?? attrs["xlink:href"] }
    var elements: [SVGImportNode] { children.filter { !$0.isText } }
    func child(_ tag: String) -> SVGImportNode? { children.first { $0.tag == tag && $0.isSVG } }
    /// Concatenated character data of this subtree.
    var textContent: String {
        if isText { return text }
        return children.map(\.textContent).joined()
    }
    var classes: [Substring] { attrs["class"]?.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) ?? [] }
}

final class SVGImportDocument {
    let root: SVGImportNode
    var ids: [String: SVGImportNode] = [:]
    var nodeCount = 0
    /// Non-fatal parse problem (the tree holds everything up to it).
    var parseWarning: String?
    /// Folder of the file (relative images), nil for pasted markup.
    var baseURL: URL?
    /// Style sheet features that were skipped (shown in the import report).
    var cssNotes: Set<String> = []

    init(root: SVGImportNode) { self.root = root }

    /// Element referenced by `#id` / `url(#id)`.
    func target(_ ref: String?) -> SVGImportNode? {
        guard var r = ref?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        if r.hasPrefix("url(") {
            r = String(r.dropFirst(4))
            if let end = r.firstIndex(of: ")") { r = String(r[..<end]) }
            r = r.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        guard r.hasPrefix("#") else { return nil }
        return ids[String(r.dropFirst()).removingPercentEncoding ?? String(r.dropFirst())]
    }
}

enum SVGImportXML {
    static let maxBytes = 256 << 20
    static let maxNodes = 400_000
    static let maxDepth = 200

    // MARK: Entry

    static func parse(_ data: Data, baseURL: URL? = nil) throws -> SVGImportDocument {
        let utf8 = try prepare(data)
        let d = Builder()
        let p = XMLParser(data: utf8)
        p.delegate = d
        p.shouldProcessNamespaces = false
        p.shouldResolveExternalEntities = false
        p.externalEntityResolvingPolicy = .never
        let ok = p.parse()
        guard let top = d.top else {
            if let e = p.parserError { throw SVGImportError.damaged(describe(e, p)) }
            throw SVGImportError.notSVG
        }
        guard let root = findSVG(top) else { throw SVGImportError.notSVG }
        root.parent = nil
        let doc = SVGImportDocument(root: root)
        doc.baseURL = baseURL
        doc.nodeCount = d.count
        if d.overflow { doc.parseWarning = "the file has more than \(maxNodes) elements; the rest was skipped" }
        else if d.tooDeep { doc.parseWarning = "elements nested deeper than \(maxDepth) levels were skipped" }
        else if !ok, let e = p.parserError { doc.parseWarning = "the file is damaged (\(describe(e, p))); everything before the error was imported" }
        index(doc)
        SVGImportCSS.cascade(doc)
        return doc
    }

    private static func describe(_ e: Error, _ p: XMLParser) -> String {
        let code = (e as NSError).code
        return "XML error \(code) at line \(p.lineNumber)"
    }

    private static func findSVG(_ n: SVGImportNode) -> SVGImportNode? {
        var queue = [n]
        var seen = 0
        while !queue.isEmpty, seen < 5000 {
            let x = queue.removeFirst()
            seen += 1
            if x.tag == "svg" && x.isSVG { return x }
            queue.append(contentsOf: x.elements)
        }
        return nil
    }

    private static func index(_ doc: SVGImportDocument) {
        var i = 0
        var stack = [doc.root]
        while let n = stack.popLast() {
            n.index = i; i += 1
            if let id = n.id, doc.ids[id] == nil { doc.ids[id] = n }
            stack.append(contentsOf: n.children.reversed())
        }
    }

    // MARK: Bytes → UTF-8 without a DOCTYPE

    /// Gunzips (.svgz), decodes to text, and replaces the DOCTYPE's internal entities by hand so that libxml2 never
    /// expands anything itself (no entity bombs, no external entities).
    static func prepare(_ raw: Data) throws -> Data {
        var data = raw
        if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
            guard let un = gunzip(data, limit: maxBytes) else { throw SVGImportError.unreadable }
            data = un
        }
        guard !data.isEmpty else { throw SVGImportError.unreadable }
        guard data.count <= maxBytes else { throw SVGImportError.tooLarge }
        var s: String
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { s = String(decoding: data.dropFirst(3), as: UTF8.self) }
        else if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { s = String(data: data, encoding: .utf16LittleEndian) ?? "" }
        else if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { s = String(data: data, encoding: .utf16BigEndian) ?? "" }
        else if b.count >= 2, b[0] == 0x3C, b[1] == 0x00 { s = String(data: data, encoding: .utf16LittleEndian) ?? "" }
        else if b.count >= 2, b[0] == 0x00, b[1] == 0x3C { s = String(data: data, encoding: .utf16BigEndian) ?? "" }
        else if let u = String(data: data, encoding: .utf8) { s = u }
        else if declaredLatin(data), let l = String(data: data, encoding: .isoLatin1) { s = l }
        else { s = String(decoding: data, as: UTF8.self) }     // damaged UTF-8: replacement characters, never a failure
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        s = s.replacingOccurrences(of: "\u{0}", with: "")
        // The XML declaration names an encoding that no longer applies. (Some files have it after a licence comment,
        // where it is a fatal error for the parser.)
        let head = s.prefix(16384)
        if let r = head.range(of: "<?xml"), let e = s.range(of: "?>", range: r.upperBound..<s.endIndex),
           head.range(of: "<svg").map({ r.lowerBound < $0.lowerBound }) ?? true {
            s.removeSubrange(r.lowerBound..<e.upperBound)
        }
        if s.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil || s.contains("<!ENTITY") { s = try stripDoctype(s) }
        // HTML entities that sloppy exporters leave in text (undefined in XML, fatal for the parser)
        if s.contains("&") {
            for (name, code) in htmlEntities where s.contains("&\(name);") { s = s.replacingOccurrences(of: "&\(name);", with: "&#\(code);") }
        }
        return Data(s.utf8)
    }

    private static let htmlEntities: [(String, Int)] = [
        ("nbsp", 160), ("copy", 169), ("reg", 174), ("trade", 8482), ("mdash", 8212), ("ndash", 8211), ("hellip", 8230), ("laquo", 171), ("raquo", 187),
        ("deg", 176), ("middot", 183), ("bull", 8226), ("lsquo", 8216), ("rsquo", 8217), ("ldquo", 8220), ("rdquo", 8221), ("times", 215), ("euro", 8364),
        ("pound", 163), ("sect", 167), ("para", 182), ("plusmn", 177), ("frac12", 189), ("shy", 173), ("ensp", 8194), ("emsp", 8195), ("thinsp", 8201),
    ]

    private static func declaredLatin(_ d: Data) -> Bool {
        let head = String(decoding: d.prefix(200), as: UTF8.self).lowercased()
        return head.contains("iso-8859") || head.contains("windows-125") || head.contains("latin")
    }

    /// Removes `<!DOCTYPE …[ … ]>` and substitutes its simple internal entities (`<!ENTITY ns "http://…">`, as written
    /// by Illustrator) in the rest of the text. Entities whose value contains markup or other entities are dropped.
    static func stripDoctype(_ s: String) throws -> String {
        guard let start = s.range(of: "<!DOCTYPE", options: .caseInsensitive) else { return s }
        // end of the declaration: the first '>' outside the internal subset and outside quotes
        var i = start.upperBound
        var inSubset = false
        var quote: Character? = nil
        var end: String.Index? = nil
        var subsetStart: String.Index? = nil, subsetEnd: String.Index? = nil
        while i < s.endIndex {
            let c = s[i]
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "[" && !inSubset { inSubset = true; subsetStart = s.index(after: i) }
            else if c == "]" && inSubset { inSubset = false; subsetEnd = i }
            else if c == ">" && !inSubset { end = i; break }
            i = s.index(after: i)
        }
        guard let e = end else {
            // unterminated DOCTYPE: nothing after it can be trusted as markup
            return String(s[..<start.lowerBound])
        }
        var entities: [String: String] = [:]
        if let a = subsetStart, let b = subsetEnd, a <= b {
            let subset = String(s[a..<b])
            let sc = Scanner(string: subset)
            sc.charactersToBeSkipped = nil
            while !sc.isAtEnd, entities.count < 256 {
                _ = sc.scanUpToString("<!ENTITY")
                guard sc.scanString("<!ENTITY") != nil else { break }
                _ = sc.scanCharacters(from: .whitespacesAndNewlines)
                guard let name = sc.scanUpToCharacters(from: .whitespacesAndNewlines), !name.hasPrefix("%") else { continue }
                _ = sc.scanCharacters(from: .whitespacesAndNewlines)
                var value: String? = nil
                if sc.scanString("\"") != nil { value = sc.scanUpToString("\"") ?? ""; _ = sc.scanString("\"") }
                else if sc.scanString("'") != nil { value = sc.scanUpToString("'") ?? ""; _ = sc.scanString("'") }
                guard let v = value, !v.contains("&"), !v.contains("<"), v.count <= 4096 else { continue }
                entities[name] = v
            }
        }
        var out = String(s[..<start.lowerBound]) + String(s[s.index(after: e)...])
        if !entities.isEmpty {
            for (name, value) in entities where out.contains("&\(name);") {
                out = out.replacingOccurrences(of: "&\(name);", with: value)
                if out.utf8.count > maxBytes { throw SVGImportError.tooLarge }
            }
        }
        return out
    }

    static func gunzip(_ data: Data, limit: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = Data()
        let chunk = 1 << 16
        var buf = [UInt8](repeating: 0, count: chunk)
        let result: Int32 = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
            guard let base = src.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            var status: Int32 = Z_OK
            while status == Z_OK {
                status = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
                    stream.next_out = bp.baseAddress
                    stream.avail_out = uInt(chunk)
                    let st = inflate(&stream, Z_NO_FLUSH)
                    let n = chunk - Int(stream.avail_out)
                    if n > 0 { out.append(bp.baseAddress!, count: n) }
                    return st
                }
                if out.count > limit { return Z_MEM_ERROR }
                if status == Z_OK && stream.avail_in == 0 && stream.avail_out != 0 { break }    // truncated stream: keep what we have
            }
            return status
        }
        if result == Z_MEM_ERROR || (result != Z_STREAM_END && out.isEmpty) { return nil }
        return out
    }

    // MARK: XMLParser delegate

    /// Elements whose character data matters.
    private static let textual: Set<String> = ["text", "tspan", "textPath", "tref", "a", "style", "title", "desc", "altGlyph"]

    /// Namespaces whose prefix matters to the importer, with the prefix the rest of the code expects ("" = SVG itself).
    private static let knownNamespaces: [String: String] = [
        "http://www.w3.org/2000/svg": "", "http://www.w3.org/1999/xlink": "xlink", "http://www.w3.org/XML/1998/namespace": "xml",
        "http://www.inkscape.org/namespaces/inkscape": "inkscape", "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd": "sodipodi",
        "http://www.bohemiancoding.com/sketch/ns": "sketch", "http://www.serif.com/": "serif",
    ]

    private final class Builder: NSObject, XMLParserDelegate {
        var top: SVGImportNode?
        var stack: [SVGImportNode] = []
        /// Prefix → canonical prefix for the prefixes a file declares differently (`xmlns:x="…/xlink"`), per open element.
        var scopes: [[String: String]] = [[:]]
        var count = 0
        var overflow = false, tooDeep = false
        /// Depth of elements being skipped (beyond the limits).
        var skipping = 0
        var foreignDepth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if skipping > 0 { skipping += 1; return }
            if count >= SVGImportXML.maxNodes { overflow = true; skipping = 1; return }
            if stack.count >= SVGImportXML.maxDepth { tooDeep = true; skipping = 1; return }
            // namespace declarations on this element
            var scope = scopes.last ?? [:]
            for (k, v) in attributes where k.hasPrefix("xmlns:") {
                let p = String(k.dropFirst(6))
                if let canon = SVGImportXML.knownNamespaces[v] { scope[p] = canon } else if scope[p] != nil || SVGImportXML.knownNamespaces.values.contains(p) { scope[p] = "ns-" + p }
            }
            scopes.append(scope)
            var tag = name, prefix: String? = nil
            if let c = name.firstIndex(of: ":") {
                prefix = String(name[..<c]); tag = String(name[name.index(after: c)...])
                if let canon = scope[prefix!] { prefix = canon.isEmpty ? nil : canon } else if prefix == "svg" { prefix = nil }
            }
            var attrs = attributes
            if !scope.isEmpty {
                for (k, v) in attributes {
                    guard let c = k.firstIndex(of: ":"), k[..<c] != "xmlns", let canon = scope[String(k[..<c])], canon != k[..<c] else { continue }
                    attrs[k] = nil
                    attrs[(canon.isEmpty ? "" : canon + ":") + k[k.index(after: c)...]] = v
                }
            }
            let n = SVGImportNode(tag: tag, prefix: prefix, attrs: attrs)
            count += 1
            if let p = stack.last { n.parent = p; p.children.append(n) } else if top == nil { top = n }
            stack.append(n)
            if tag == "foreignObject" || foreignDepth > 0 { foreignDepth += 1 }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if skipping > 0 { skipping -= 1; return }
            if scopes.count > 1 { scopes.removeLast() }
            if foreignDepth > 0 { foreignDepth -= 1 }
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { add(string) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { add(String(decoding: CDATABlock, as: UTF8.self)) }

        private func add(_ s: String) {
            guard skipping == 0, let p = stack.last, foreignDepth > 0 || (p.isSVG && SVGImportXML.textual.contains(p.tag)) else { return }
            if let last = p.children.last, last.isText { last.text += s; return }
            let t = SVGImportNode(tag: "#text", prefix: nil, attrs: [:])
            t.text = s
            t.parent = p
            p.children.append(t)
        }
    }
}

// MARK: - CSS

/// A practical subset of CSS for `<style>` sheets: type, class, id, universal and attribute selectors, compound
/// selectors, descendant / child combinators and selector lists; `!important`; custom properties.
enum SVGImportCSS {
    struct Compound {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attrs: [(name: String, op: String, value: String)] = []
        var root = false
        var specificity: Int { (id == nil ? 0 : 10000) + (classes.count + attrs.count + (root ? 1 : 0)) * 100 + (tag == nil ? 0 : 1) }
    }
    struct Selector {
        /// Right-most compound first; `combinator` links a compound to the next one in the array (its ancestor side).
        var parts: [(compound: Compound, combinator: Character)]
        var specificity: Int { parts.reduce(0) { $0 + $1.compound.specificity } }
    }
    struct Rule {
        var selector: Selector
        var decls: [(name: String, value: String, important: Bool)]
        var order: Int
    }

    /// Attributes that are presentation properties (everything else is geometry or metadata).
    static let presentation: Set<String> = [
        "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
        "stroke-dasharray", "stroke-dashoffset", "stroke-opacity", "opacity", "display", "visibility", "color", "font-family", "font-size",
        "font-weight", "font-style", "font-variant", "font-stretch", "text-anchor", "text-decoration", "letter-spacing", "word-spacing",
        "dominant-baseline", "alignment-baseline", "baseline-shift", "clip-path", "clip-rule", "mask", "filter", "mix-blend-mode", "isolation",
        "stop-color", "stop-opacity", "marker-start", "marker-mid", "marker-end", "paint-order", "vector-effect", "overflow", "writing-mode",
        "direction", "shape-rendering", "text-rendering", "image-rendering", "flood-color", "flood-opacity", "lighting-color", "white-space",
        "mask-type", "transform-origin", "transform-box", "line-height", "unicode-bidi", "font-kerning", "cursor", "pointer-events",
        "color-interpolation-filters", "color-interpolation", "enable-background", "text-transform", "font-feature-settings", "font-variation-settings",
    ]

    static func cascade(_ doc: SVGImportDocument) {
        var rules: [Rule] = []
        var sheets: [SVGImportNode] = []
        var stack = [doc.root]
        while let n = stack.popLast() {
            if n.tag == "style" && n.isSVG { sheets.append(n) }
            stack.append(contentsOf: n.children.reversed())
        }
        sheets.sort { $0.index < $1.index }
        for s in sheets {
            let type = s.attrs["type"]?.lowercased() ?? "text/css"
            guard type.isEmpty || type.contains("css") else { continue }
            rules += parseSheet(s.textContent, firstOrder: rules.count, notes: &doc.cssNotes)
            if rules.count > 20000 { doc.cssNotes.insert("very large style sheet (truncated)"); break }
        }
        // index the rules by the right-most compound so matching stays linear in the document size
        var byID: [String: [Int]] = [:], byClass: [String: [Int]] = [:], byTag: [String: [Int]] = [:], rest: [Int] = []
        for (i, r) in rules.enumerated() {
            let c = r.selector.parts[0].compound
            if let id = c.id { byID[id, default: []].append(i) }
            else if let cl = c.classes.first { byClass[cl, default: []].append(i) }
            else if let t = c.tag { byTag[t, default: []].append(i) }
            else { rest.append(i) }
        }
        stack = [doc.root]
        while let n = stack.popLast() {
            stack.append(contentsOf: n.children.reversed())
            guard !n.isText else { continue }
            var found: [String: (String, Int)] = [:]
            func put(_ name: String, _ value: String, _ prio: Int) {
                for (k, v) in expand(name, value) where valid(k, v) {
                    if let old = found[k], old.1 > prio { continue }
                    found[k] = (v, prio)
                }
            }
            for (k, v) in n.attrs where presentation.contains(k) { put(k, v, 0) }
            if !rules.isEmpty {
                var cand: [Int] = rest
                if let id = n.id, let l = byID[id] { cand += l }
                for c in n.classes { if let l = byClass[String(c)] { cand += l } }
                if let l = byTag[n.tag] { cand += l }
                for i in cand.sorted() where matches(rules[i].selector, n, doc.root) {
                    let r = rules[i]
                    let base = 1 + r.selector.specificity * 100_000
                    for d in r.decls { put(d.name, d.value, (d.important ? 2_000_000_000_000 : 0) + base * 1 + r.order % 100_000) }
                }
            }
            if let st = n.attrs["style"] {
                for d in parseDeclarations(st) { put(d.name, d.value, d.important ? 3_000_000_000_000 : 1_000_000_000_000) }
            }
            if !found.isEmpty { n.decls = found.mapValues { $0.0 } }
        }
    }

    /// CSS drops a declaration whose value it cannot parse, so an earlier or less specific valid one stays in force.
    /// Checked for the properties where exporters actually produce junk.
    static func valid(_ name: String, _ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = v.lowercased()
        if l.contains("var(") || l == "inherit" || l == "initial" || l == "unset" || l == "revert" { return true }
        switch name {
        case "fill", "stroke": return SVGImportPaint.parse(v) != nil
        case "color", "stop-color", "flood-color": return l == "currentcolor" || SVGImportValue.color(v) != nil
        case "opacity", "fill-opacity", "stroke-opacity", "stop-opacity", "stroke-miterlimit": return SVGImportValue.number(v) != nil
        case "stroke-width": return SVGImportValue.length(v) != nil
        default: return true
        }
    }

    /// Shorthands → longhands.
    static func expand(_ name: String, _ value: String) -> [(String, String)] {
        switch name {
        case "marker": return [("marker-start", value), ("marker-mid", value), ("marker-end", value)]
        case "text-decoration-line": return [("text-decoration", value)]
        case "font":
            // [style] [variant] [weight] size[/line-height] family
            var out: [(String, String)] = []
            let parts = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let si = parts.firstIndex(where: { $0.first.map { $0.isNumber || $0 == "." } ?? false }) else { return [] }
            for p in parts[..<si] {
                let l = p.lowercased()
                if l == "italic" || l == "oblique" { out.append(("font-style", l)) }
                else if l == "bold" || l == "bolder" || l == "lighter" || Int(l) != nil { out.append(("font-weight", l)) }
            }
            out.append(("font-size", String(parts[si].split(separator: "/")[0])))
            let fam = parts[(si + 1)...].joined(separator: " ")
            if !fam.isEmpty { out.append(("font-family", fam)) }
            return out
        default: return [(name, value)]
        }
    }

    // MARK: Parsing

    static func stripComments(_ s: String) -> String {
        guard s.contains("/*") else { return s }
        var out = ""
        var rest = Substring(s)
        while let a = rest.range(of: "/*") {
            out += rest[..<a.lowerBound]
            guard let b = rest.range(of: "*/", range: a.upperBound..<rest.endIndex) else { return out }
            rest = rest[b.upperBound...]
        }
        return out + rest
    }

    static func parseSheet(_ text: String, firstOrder: Int, notes: inout Set<String>) -> [Rule] {
        let chars = Array(stripComments(text).replacingOccurrences(of: "<!--", with: "").replacingOccurrences(of: "-->", with: ""))
        var rules: [Rule] = []
        var i = 0
        let n = chars.count
        var order = firstOrder
        /// Index just past the block that starts at `open` (a '{').
        func blockEnd(_ open: Int) -> Int {
            var depth = 0, j = open
            var quote: Character? = nil
            while j < n {
                let c = chars[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return n
        }
        while i < n, rules.count < 20001 {
            // prelude up to '{' or ';'
            var j = i
            var quote: Character? = nil
            while j < n {
                let c = chars[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == "{" || c == ";" { break }
                j += 1
            }
            if j >= n { break }
            let prelude = String(chars[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines)
            if chars[j] == ";" { i = j + 1; if prelude.hasPrefix("@import") { notes.insert("@import (external style sheets are not loaded)") }; continue }
            let end = blockEnd(j)
            let closing = end > j + 1 && chars[end - 1] == "}" ? end - 1 : end
            let body = String(chars[(j + 1)..<max(j + 1, closing)])
            i = end
            if prelude.hasPrefix("@") {
                let l = prelude.lowercased()
                if l.hasPrefix("@media") {
                    // screen rules apply; print and feature queries do not
                    let q = l.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    if q.isEmpty || q == "all" || q == "screen" || q == "only screen" {
                        let inner = parseSheet(body, firstOrder: order, notes: &notes)
                        rules += inner; order += inner.count
                    } else { notes.insert("@media queries") }
                } else if l.hasPrefix("@font-face") { notes.insert("@font-face (embedded web fonts are not loaded)") }
                else if l.hasPrefix("@keyframes") || l.hasPrefix("@-webkit-keyframes") { notes.insert("CSS animation") }
                continue
            }
            let decls = parseDeclarations(body)
            guard !decls.isEmpty else { continue }
            for selText in splitTopLevel(prelude, ",") {
                guard let sel = parseSelector(selText) else { notes.insert("unsupported CSS selector “\(selText.trimmingCharacters(in: .whitespaces).prefix(40))”"); continue }
                rules.append(Rule(selector: sel, decls: decls, order: order))
                order += 1
            }
        }
        return rules
    }

    /// Splits on `sep` outside parentheses, brackets and quotes.
    static func splitTopLevel(_ s: String, _ sep: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var depth = 0
        var quote: Character? = nil
        for c in s {
            if let q = quote { cur.append(c); if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; cur.append(c); continue }
            if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { depth = max(0, depth - 1) }
            if c == sep && depth == 0 { out.append(cur); cur = "" } else { cur.append(c) }
        }
        out.append(cur)
        return out
    }

    static func parseDeclarations(_ s: String) -> [(name: String, value: String, important: Bool)] {
        var out: [(String, String, Bool)] = []
        for part in splitTopLevel(stripComments(s), ";") {
            guard let c = part.firstIndex(of: ":") else { continue }
            var name = part[..<c].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = part[part.index(after: c)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            if !name.hasPrefix("--") { name = name.lowercased() }
            var important = false
            if let r = value.range(of: "!important", options: [.caseInsensitive, .backwards]) {
                important = true
                value = value[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if name.hasPrefix("-webkit-") || name.hasPrefix("-moz-") || name.hasPrefix("-ms-") { continue }
            out.append((name, value, important))
        }
        return out
    }

    static func parseSelector(_ text: String) -> Selector? {
        let s = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !s.isEmpty else { return nil }
        var compounds: [Compound] = []
        var combinators: [Character] = []
        var i = 0
        let n = s.count
        func ident() -> String {
            var out = ""
            while i < n {
                let c = s[i]
                if c == "\\" && i + 1 < n { out.append(s[i + 1]); i += 2; continue }
                if c.isLetter || c.isNumber || c == "-" || c == "_" || (c.unicodeScalars.first!.value > 127) { out.append(c); i += 1 } else { break }
            }
            return out
        }
        while i < n {
            var c = Compound()
            var any = false
            loop: while i < n {
                switch s[i] {
                case "*": i += 1; any = true
                case "#": i += 1; let v = ident(); if v.isEmpty { return nil }; c.id = v; any = true
                case ".": i += 1; let v = ident(); if v.isEmpty { return nil }; c.classes.append(v); any = true
                case "[":
                    guard let close = s[i...].firstIndex(of: "]") else { return nil }
                    let inner = String(s[(i + 1)..<close])
                    i = close + 1
                    var name = inner, op = "", value = ""
                    for candidate in ["~=", "|=", "^=", "$=", "*=", "="] {
                        if let r = inner.range(of: candidate) {
                            name = String(inner[..<r.lowerBound]); op = candidate
                            value = String(inner[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                            break
                        }
                    }
                    c.attrs.append((name.trimmingCharacters(in: .whitespaces), op, value)); any = true
                case ":":
                    // only :root is understood; anything else (states, structural pseudo-classes, pseudo-elements) never matches
                    i += 1
                    if i < n, s[i] == ":" { return nil }
                    let v = ident().lowercased()
                    if v == "root" { c.root = true; any = true } else { return nil }
                case " ", "\t", "\n", "\r", ">", "+", "~": break loop
                default:
                    let v = ident()
                    if v.isEmpty { return nil }
                    c.tag = v; any = true
                }
            }
            guard any else { return nil }
            compounds.append(c)
            // combinator
            var comb: Character = " "
            while i < n, s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r" || s[i] == ">" || s[i] == "+" || s[i] == "~" {
                if s[i] == ">" || s[i] == "+" || s[i] == "~" { comb = s[i] }
                i += 1
            }
            if i < n { combinators.append(comb) }
        }
        guard !compounds.isEmpty, compounds.count <= 12 else { return nil }
        var parts: [(Compound, Character)] = []
        for k in stride(from: compounds.count - 1, through: 0, by: -1) {
            parts.append((compounds[k], k > 0 ? combinators[k - 1] : " "))
        }
        return Selector(parts: parts)
    }

    // MARK: Matching

    static func matches(_ c: Compound, _ n: SVGImportNode, _ root: SVGImportNode) -> Bool {
        if let t = c.tag, t != n.tag { return false }
        if let id = c.id, id != n.id { return false }
        if c.root && n !== root { return false }
        if !c.classes.isEmpty {
            let cl = n.classes
            for want in c.classes where !cl.contains(where: { $0 == want }) { return false }
        }
        for a in c.attrs {
            guard let v = n.attrs[a.name] else { return false }
            switch a.op {
            case "": break
            case "=": if v != a.value { return false }
            case "~=": if !v.split(separator: " ").contains(where: { $0 == a.value }) { return false }
            case "|=": if !(v == a.value || v.hasPrefix(a.value + "-")) { return false }
            case "^=": if a.value.isEmpty || !v.hasPrefix(a.value) { return false }
            case "$=": if a.value.isEmpty || !v.hasSuffix(a.value) { return false }
            case "*=": if a.value.isEmpty || !v.contains(a.value) { return false }
            default: return false
            }
        }
        return true
    }

    static func matches(_ sel: Selector, _ node: SVGImportNode, _ root: SVGImportNode) -> Bool {
        func step(_ k: Int, _ n: SVGImportNode) -> Bool {
            guard matches(sel.parts[k].compound, n, root) else { return false }
            if k == sel.parts.count - 1 { return true }
            let comb = sel.parts[k].combinator
            var p = n.parent
            if comb == ">" { return p.map { step(k + 1, $0) } ?? false }
            if comb == "+" || comb == "~" {
                // earlier element siblings (the nearest one only for '+')
                guard let sibs = p?.children, let at = sibs.firstIndex(where: { $0 === n }) else { return false }
                var j = at - 1
                while j >= 0 {
                    if !sibs[j].isText {
                        if step(k + 1, sibs[j]) { return true }
                        if comb == "+" { return false }
                    }
                    j -= 1
                }
                return false
            }
            while let a = p {
                if step(k + 1, a) { return true }
                p = a.parent
            }
            return false
        }
        return step(0, node)
    }
}
