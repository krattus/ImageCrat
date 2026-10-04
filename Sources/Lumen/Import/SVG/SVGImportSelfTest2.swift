import AppKit
import zlib
import ImageCratCore

// SVG import self tests, part 2: parser units, hostile input, fuzzing, round trips through Lumen's own SVG exporters,
// and the app integration (open, place, replace, linked, paste, report).

extension SVGImportSelfTest {
    private static func load(_ svg: String, _ configure: (inout SVGImportSettings) -> Void = { _ in }) -> SVGImportResult? {
        var s = SVGImportSettings()
        s.minimumSide = 0
        configure(&s)
        return try? SVGImport.load(data: Data(svg.utf8), name: "test.svg", settings: s)
    }

    static func gzip(_ data: Data) -> Data {
        var stream = z_stream()
        deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: data.count + 256)
        let n: Int = data.withUnsafeBytes { src in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            return out.withUnsafeMutableBufferPointer { dst in
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(dst.count)
                deflate(&stream, Z_FINISH)
                return dst.count - Int(stream.avail_out)
            }
        }
        return Data(out.prefix(n))
    }

    // MARK: Units

    static func units() {
        // numbers
        check(SVGImportValue.numbers(".5.5-3e1 1E1,2 ,3") == [0.5, 0.5, -30, 10, 2, 3], "number lists without separators (\(SVGImportValue.numbers(".5.5-3e1 1E1,2 ,3")))")
        check(SVGImportValue.number("1e400") == nil && SVGImportValue.number("abc") == nil && SVGImportValue.number("-") == nil, "overflowing and malformed numbers are rejected")
        check(SVGImportValue.number("50%") == 0.5 && SVGImportValue.number(" 0.25 ") == 0.25, "percentages as fractions")
        check(SVGImportValue.length("2em")?.unit == .em && SVGImportValue.length("1in")?.value == 96 && abs((SVGImportValue.length("10mm")?.value ?? 0) - 37.795) < 0.001
              && SVGImportValue.length("12pt")?.value == 16 && SVGImportValue.length("1e3px")?.value == 1000 && SVGImportValue.length("4furlongs") == nil, "length units")
        // paths
        func bb(_ d: String) -> CGRect { SVGImportValue.path(d).boundingBoxOfPath }
        check(bb("M0 0L10 0 10 10z").equalTo(CGRect(x: 0, y: 0, width: 10, height: 10), tolerance: 1e-9), "implicit line-to repetition")
        check(bb("m10 10 10 0 0 10-10 0z m30 0h10v10h-10z").equalTo(CGRect(x: 10, y: 10, width: 40, height: 10), tolerance: 1e-9), "relative move after close starts from the subpath start (\(bb("m10 10 10 0 0 10-10 0z m30 0h10v10h-10z")))")
        check(bb("M10 50 A40 40 0 0 1 90 50").equalTo(CGRect(x: 10, y: 10, width: 80, height: 40), tolerance: 0.01), "arc: upper half circle (\(bb("M10 50 A40 40 0 0 1 90 50")))")
        check(bb("M10 50 A40 40 0 0 0 90 50").equalTo(CGRect(x: 10, y: 50, width: 80, height: 40), tolerance: 0.01), "arc: sweep flag flips the side")
        check(bb("M10 50 A10 10 0 0 1 90 50").equalTo(CGRect(x: 10, y: 10, width: 80, height: 40), tolerance: 0.01), "arc: too-small radii are scaled up")
        check(bb("M10 50a40 40 0 1150 30").width > 60, "arc flags without separators")
        check(bb("M0 0 C0 10 10 10 10 0 S20 -10 20 0").equalTo(CGRect(x: 0, y: -7.5, width: 20, height: 15), tolerance: 0.01), "smooth cubic reflects the control point (\(bb("M0 0 C0 10 10 10 10 0 S20 -10 20 0")))")
        check(bb("M0 0 Q5 10 10 0 T20 0").equalTo(CGRect(x: 0, y: -5, width: 20, height: 10), tolerance: 0.01), "smooth quadratic reflects the control point")
        check(bb("M0 0 L10 10 L oops 20 20").equalTo(CGRect(x: 0, y: 0, width: 10, height: 10), tolerance: 1e-9), "path data is kept up to the first error")
        check(SVGImportValue.path("L10 10").isEmpty && SVGImportValue.path("").isEmpty && SVGImportValue.path("M").isEmpty, "path data must start with a move-to")
        check(abs(SVGImportValue.length(of: SVGImportValue.path("M0 0 H30 V40 Z")) - 120) < 1e-6, "path length")
        // transforms
        func ap(_ t: String, _ x: CGFloat, _ y: CGFloat) -> CGPoint? { SVGImportValue.transform(t).map { CGPoint(x: x, y: y).applying($0) } }
        func near(_ p: CGPoint?, _ x: CGFloat, _ y: CGFloat) -> Bool { p.map { abs($0.x - x) < 1e-6 && abs($0.y - y) < 1e-6 } ?? false }
        check(near(ap("translate(10,20) scale(2)", 1, 1), 12, 22), "transform lists apply right to left")
        check(near(ap("rotate(90)", 1, 0), 0, 1) && near(ap("rotate(90 10 10)", 10, 0), 20, 10), "rotate, with and without a centre")
        check(near(ap("skewX(45)", 0, 10), 10, 10) && near(ap("skewY(45)", 10, 0), 10, 10) && near(ap("matrix(1 2 3 4 5 6)", 1, 1), 9, 12), "skew and matrix")
        check(near(ap("translate(5px, 6px) rotate(0.25turn)", 1, 0), 5, 7), "CSS units in transform functions")
        check(SVGImportValue.transform("bogus(1)") == nil && SVGImportValue.transform("matrix(1 2 3)") == nil && SVGImportValue.transform("") == nil, "invalid transforms are rejected")
        // colours
        func hex(_ s: String) -> String? { SVGImportValue.color(s).map { $0.hex + ($0.a < 0.999 ? String(format: "/%.2f", $0.a) : "") } }
        check(hex("red") == "FF0000" && hex("#0f0") == "00FF00" && hex("#00f8") == "0000FF/0.53" && hex("rgb(255, 128, 0)") == "FF8000" && hex("rgb(50%,0%,100%)") == "8000FF"
              && hex("rgba(0,0,0,.5)") == "000000/0.50" && hex("hsl(120, 100%, 25%)") == "008000" && hex("hsl(0.5turn 100% 50% / 25%)") == "00FFFF/0.25" && hex("RebeccaPurple") == "663399"
              && hex("transparent") == "000000/0.00", "colour syntaxes")
        check(hex("nope") == nil && hex("#12") == nil && hex("rgb(1,2)") == nil && hex("") == nil, "invalid colours are rejected")
        // CSS
        var notes = Set<String>()
        let rules = SVGImportCSS.parseSheet("a, .b > c#d { fill: red; stroke: url('data:image/png;base64,AA;BB') !important } @media print { x { fill: blue } } /* c */ e f{}", firstOrder: 0, notes: &notes)
        check(rules.count == 2 && rules[1].selector.parts.count == 2 && rules[1].selector.parts[1].combinator == " " && rules[1].selector.parts[0].combinator == ">"
              && rules[0].decls.count == 2 && rules[0].decls[1].important && rules[0].decls[1].value.contains(";BB"), "style sheet parsing (\(rules.count) rules)")
        check(notes.contains("@media queries"), "skipped style sheet features are noted")
        // XML preparation
        let ent = "<?xml version='1.0' encoding='ISO-8859-1'?><!DOCTYPE svg [ <!ENTITY a 'http://www.w3.org/2000/svg'> <!ENTITY bomb '&a;&a;&a;'> <!ENTITY % p 'x'> ]><svg xmlns='&a;' width='10' height='10'>&bomb;<rect width='5' height='5'/></svg>"
        let prepared = (try? SVGImportXML.prepare(Data(ent.utf8))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(prepared.contains("xmlns='http://www.w3.org/2000/svg'") && !prepared.contains("DOCTYPE") && !prepared.contains("<?xml"), "DOCTYPE entities are substituted by hand: \(prepared.prefix(70))")
        let utf16 = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><title>ä€</title><rect width='20' height='10' fill='#123'/></svg>".data(using: .utf16)!
        check((try? SVGImport.load(data: utf16, name: "u.svg"))?.state.layers.first?.isShape == true, "UTF-16 input")
        let plain = "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10' fill='#123'/></svg>"
        let gz = gzip(Data(plain.utf8))
        check(gz.count > 20 && gz[0] == 0x1f && (try? SVGImport.load(data: gz, name: "z.svgz"))?.state.layers.first?.isShape == true, "gzip-compressed input (svgz)")
        check((try? SVGImport.load(data: gz.prefix(gz.count / 2), name: "z.svgz")) == nil || true, "truncated gzip does not crash")
        check(load("<!-- licence -->\n<?xml version='1.0' standalone='no'?>\n<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10'/></svg>")?.state.layers.first?.isShape == true,
              "an XML declaration after a leading comment is tolerated")
        check(load("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><text x='1' y='15' font-size='10'>a&nbsp;b &copy;</text></svg>")?.state.layers.first?.text?.text == "a\u{a0}b ©", "HTML entities in text")
        // sizes
        func natural(_ attrs: String, _ body: String = "") -> CGSize { (try? SVGImportXML.parse(Data("<svg xmlns='http://www.w3.org/2000/svg' \(attrs)>\(body)</svg>".utf8))).map { SVGImport.naturalSize($0) } ?? .zero }
        check(natural("width='120' height='80'") == CGSize(width: 120, height: 80) && natural("viewBox='0 0 50 25'") == CGSize(width: 50, height: 25)
              && natural("width='100' viewBox='0 0 50 25'") == CGSize(width: 100, height: 50) && natural("width='100%' height='100%' viewBox='5 5 30 60'") == CGSize(width: 30, height: 60)
              && natural("width='2in' height='1in'") == CGSize(width: 192, height: 96), "natural size from width / height / viewBox")
        check(natural("", "<rect x='10' y='20' width='90' height='40'/>") == CGSize(width: 100, height: 60) && natural("") == CGSize(width: 300, height: 150), "natural size without any size information")
        check(SVGImport.defaultPixelSize(CGSize(width: 24, height: 24)) == (264, 264) && SVGImport.defaultPixelSize(CGSize(width: 300, height: 150)) == (300, 150)
              && SVGImport.defaultPixelSize(CGSize(width: 50000, height: 25000)) == (16384, 8192) && SVGImport.defaultPixelSize(CGSize(width: 16, height: 8), minimumSide: 0) == (16, 8), "default pixel size (tiny artwork is opened at a whole multiple)")
        check(SVGImportNames.isGenerated("g1234") && SVGImportNames.isGenerated("path-7") && SVGImportNames.isGenerated("SVGID_1_") && !SVGImportNames.isGenerated("logo") && !SVGImportNames.isGenerated("Layer_1")
              && SVGImportNames.clean("A_x20_B_x2F_C") == "A B/C", "generated ids are recognised, Illustrator escapes decoded")
        check(SVGImport.looksLikeSVG("  <?xml version='1.0'?>\n<!-- c -->\n<svg xmlns='x'>") && SVGImport.looksLikeSVG("<svg>") && !SVGImport.looksLikeSVG("<svgx>") && !SVGImport.looksLikeSVG("hello <svg>")
              && !SVGImport.looksLikeSVG("<html><svg/></html>"), "SVG sniffing for the pasteboard")
    }

    // MARK: Hostile input

    static func hostile() {
        func timed(_ name: String, limit: Double = 6, _ body: () -> Bool) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let ok = body()
            let dt = CFAbsoluteTimeGetCurrent() - t0
            check(ok && dt < limit, "\(name) (\(String(format: "%.2f", dt)) s)")
            Compositor.shared.clearCaches()
        }
        let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"
        timed("use referencing itself, its ancestor and a cycle") {
            let r = load("<svg \(ns) width='40' height='40'><g id='a'><use href='#a'/><use id='u' href='#u'/><g id='b'><use href='#c'/></g><g id='c'><use href='#b'/><rect width='10' height='10'/></g></g></svg>")
            return r != nil && (r!.state.allLayers.filter(\.isShape).count >= 1)
        }
        timed("use bomb (10 levels of 10 references each) stops at the element budget") {
            var s = "<svg \(ns) width='40' height='40'><defs><rect id='l0' width='1' height='1'/>"
            for i in 1...10 { s += "<g id='l\(i)'>" + String(repeating: "<use href='#l\(i - 1)'/>", count: 10) + "</g>" }
            s += "</defs><use href='#l10'/></svg>"
            guard let r = load(s) else { return false }
            return r.report.items.contains { $0.kind == .warning && $0.message.contains("too complex") } && r.state.allLayers.count <= SVGImportBuilder.elementBudget + 100
        }
        timed("deep nesting of groups, viewports and links") {
            let s = "<svg \(ns) width='40' height='40'>" + String(repeating: "<g transform='translate(.1)' opacity='.99'><svg><a>", count: 90) + "<rect width='10' height='10'/>" + String(repeating: "</a></svg></g>", count: 90) + "</svg>"
            return load(s) != nil
        }
        timed("5000 nested groups") {
            let s = "<svg \(ns) width='40' height='40'>" + String(repeating: "<g>", count: 5000) + "<rect width='10' height='10'/>" + String(repeating: "</g>", count: 5000) + "</svg>"
            let r = load(s)
            return r != nil && r!.report.items.contains { $0.kind == .warning }
        }
        timed("entity expansion bomb") {
            var s = "<?xml version='1.0'?><!DOCTYPE svg [<!ENTITY a0 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'>"
            for i in 1...30 { s += "<!ENTITY a\(i) '&a\(i - 1);&a\(i - 1);&a\(i - 1);&a\(i - 1);'>" }
            s += "]><svg \(ns) width='40' height='40'><title>&a30;</title><rect width='10' height='10'/></svg>"
            // nested entities are dropped, so the reference is undefined: a parse error or an import, never an expansion
            let r = try? SVGImport.load(data: Data(s.utf8), name: "bomb.svg")
            return r == nil || r!.state.allLayers.count <= 2
        }
        timed("8000 shapes import in reasonable time", limit: 30) {
            var s = "<svg \(ns) width='400' height='400'>"
            for i in 0..<8000 { s += "<rect x='\(i % 100 * 4)' y='\(i / 100 * 4)' width='3' height='3' fill='#\(String(format: "%06x", i * 2000 % 0xffffff))'/>" }
            guard let r = load(s + "</svg>") else { return false }
            return r.state.layers.count == 8000
        }
        timed("path with 200 000 coordinates") {
            var d = "M0 0"
            for i in 0..<100_000 { d += " L\(i % 300) \((i * 7) % 200)" }
            guard let r = load("<svg \(ns) width='300' height='200'><path d='\(d)' fill='none' stroke='black'/></svg>") else { return false }
            return r.state.layers.first?.shape?.path.subpaths.first?.points.count == 100_001
        }
        timed("reference cycles in gradients, clip paths, masks, patterns and filters") {
            let s = "<svg \(ns) width='60' height='40'><defs><linearGradient id='g1' href='#g2'/><linearGradient id='g2' href='#g1'><stop stop-color='red'/></linearGradient>"
                + "<clipPath id='c1' clip-path='url(#c2)'><rect width='30' height='30'/></clipPath><clipPath id='c2' clip-path='url(#c1)'><rect width='30' height='30'/><use href='#c2'/></clipPath>"
                + "<mask id='m1'><rect width='60' height='40' fill='#fff' mask='url(#m1)'/></mask><pattern id='p1' width='4' height='4' patternUnits='userSpaceOnUse'><rect width='4' height='4' fill='url(#p1)'/></pattern>"
                + "<filter id='f1'><feImage href='#r'/></filter></defs>"
                + "<rect id='r' width='20' height='20' fill='url(#g1)' clip-path='url(#c1)' mask='url(#m1)'/><rect x='30' width='20' height='20' fill='url(#p1)' filter='url(#f1)'/>"
                + "<rect y='25' width='10' height='10' fill='url(#nope)' clip-path='url(#nope)' mask='url(#nope)' filter='url(#nope)' stroke='url(#g2)'/></svg>"
            return load(s) != nil
        }
        timed("non-finite and absurd root sizes") {
            for root in ["width='NaN' height='inf'", "viewBox='0 0 0 0'", "viewBox='0 0 -5 1e400'", "width='1e12' height='1e12'", "width='0' height='0'", "width='-10' height='20' viewBox='a b c d'", "width='1e-9' height='1e-9'"] {
                guard let r = load("<svg \(ns) \(root)><rect width='10' height='10'/></svg>"), r.state.width >= 1, r.state.height >= 1, r.state.width <= SVGImport.maxSide, r.state.height <= SVGImport.maxSide else { return false }
                _ = SVGImportQA.lumen(r.state.width * r.state.height < 4_000_000 ? r.state : DocumentState(width: 1, height: 1))
            }
            return true
        }
        timed("absurd numbers in geometry, strokes, fonts and gradients composite without trouble") {
            let s = "<svg \(ns) width='80' height='60'><defs><linearGradient id='g' x1='-1e38' x2='1e38' gradientTransform='scale(1e30)'><stop offset='-5' stop-color='red'/><stop offset='1e9' stop-color='blue' stop-opacity='-3'/></linearGradient>"
                + "<radialGradient id='r' r='1e-30' fx='1e30'><stop stop-color='red'/><stop offset='1' stop-color='blue'/></radialGradient></defs>"
                + "<rect width='1e38' height='1e38' fill='url(#g)' stroke='black' stroke-width='1e30' stroke-dasharray='1e-30 1e30' stroke-miterlimit='1e30'/>"
                + "<circle r='3e38' fill='url(#r)' opacity='1e9'/><ellipse rx='1e-38' ry='1e38' transform='matrix(1e38 1e38 -1e38 1e38 1e38 1e38)'/>"
                + "<text x='1e30' y='-1e30' font-size='1e30' letter-spacing='1e30'>huge</text><text font-size='0'>zero</text><text font-size='1e-30' x='10' y='10'>tiny</text>"
                + "<path d='M0 0 A1e38 1e-38 1e38 1 1 1e38 1e38 Q1e38 -1e38 0 0' stroke='red' stroke-width='3e38'/><image width='1e38' height='1e38' href='data:image/png;base64,AAAA'/>"
                + "<g transform='scale(1e-30)'><rect width='1e30' height='1e30' fill='green'/></g><rect width='10' height='10' rx='1e38' ry='-1'/></svg>"
            guard let r = load(s) else { return false }
            return SVGImportQA.lumen(r.state) != nil
        }
        timed("damaged files give a partial document or an error") {
            let whole = "<svg \(ns) width='60' height='40'><rect id='first' width='20' height='20' fill='#c33'/><g><circle cx='40' cy='20' r='10'/><path d='M0 0 L10"
            guard let r = try? SVGImport.load(data: Data(whole.utf8), name: "cut.svg") else { return false }
            let partial = r.state.allLayers.contains { $0.name == "first" } && r.report.items.contains { $0.kind == .warning && $0.message.contains("damaged") }
            var threw = 0
            for junk in ["", "   ", "hello", "<html><body>x</body></html>", "<svg", "<?xml version='1.0'?>", "\u{0}\u{1}\u{2}", "<svg></svg><svg>", "<a><b></a></b>"] {
                do { _ = try SVGImport.load(data: Data(junk.utf8), name: "junk.svg") } catch { threw += 1 }
            }
            let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) })
            if (try? SVGImport.load(data: bytes, name: "bytes.svg")) == nil { threw += 1 }
            return partial && threw >= 7
        }
        timed("hundreds of elements that need pixels: flattened instead of hundreds of pixel layers", limit: 30) {
            var s = "<svg \(ns) width='200' height='200'><defs><filter id='b'><feGaussianBlur stdDeviation='1'/></filter></defs>"
            for i in 0..<(SVGImport.maxRasterJobs + 20) { s += "<rect x='\(i % 20 * 10)' y='\(i / 20 * 10)' width='8' height='8' fill='#c03' filter='url(#b)'/>" }
            guard let r = load(s + "</svg>") else { return false }
            return r.state.layers.count == 1 && r.state.layers[0].isRaster && r.report.flattened && r.report.items.contains { $0.message.contains("flattened instead") }
        }
        timed("images: garbage data, self-reference depth, files outside the folder") {
            let inner = "<svg \(ns) width='10' height='10'><rect width='10' height='10' fill='red'/></svg>"
            var nested = inner
            for _ in 0..<6 { nested = "<svg \(ns) width='10' height='10'><image width='10' height='10' href='data:image/svg+xml;base64,\(Data(nested.utf8).base64EncodedString())'/></svg>" }
            let s = "<svg \(ns) width='60' height='40'><image width='10' height='10' href='data:image/png;base64,!!!notbase64'/><image width='10' height='10' href='data:image/png;base64,\(Data("not a png".utf8).base64EncodedString())'/>"
                + "<image width='10' height='10' href='/etc/hosts'/><image width='10' height='10' href='../../../../etc/passwd'/><image width='10' height='10' href='file:///etc/hosts'/><image width='10' height='10' href=''/></svg>"
            return load(s) != nil && load(nested) != nil
        }
    }

    // MARK: Fuzzing

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Truncated and mutated corpus files: the importer has to return a document or throw, quickly, every time.
    static func fuzz(_ count: Int) {
        var corpus = SVGImportCorpus.cases().map(\.svg).filter { $0.utf8.count < 6000 }
        // LUMEN_SVGIMPORT_FUZZ_SEEDS=<text file of paths>: mutate real files instead of the built-in corpus
        if let list = ProcessInfo.processInfo.environment["LUMEN_SVGIMPORT_FUZZ_SEEDS"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) {
            let seeds = list.split(separator: "\n").compactMap { p -> String? in
                guard let d = try? Data(contentsOf: URL(fileURLWithPath: String(p))), d.count < 60_000 else { return nil }
                return String(data: d, encoding: .utf8)
            }
            if !seeds.isEmpty { corpus = seeds }
        }
        let tokens = ["<use href='#a'/>", " transform='matrix(1e38 0 0 1e-38 0 0)'", "1e999", "NaN", "-", "&#x0;", "<!--", "]]>", "url(#", "%", "<svg>", "</g>", "<g>", "'", "\"", "<", ">", "&amp;", "&bogus;",
                      " d='M0 0A1 1 0 0 0", " viewBox='0 0 0 0'", "<style>*{fill:url(#x) !important}</style>", " style='transform:rotate(1turn) scale(0)'", "\u{0}", "é", "<![CDATA[", " x='1e30'",
                      "<mask id='m'><g mask='url(#m)'/></mask>", " href='#'", " clip-path='url(#c)'", "<clipPath id='c'><use href='#c'/></clipPath>", " stroke-dasharray='0 0 0'", " font-size='-1'", " rx='1e38'"]
        var rng = SplitMix(state: 0x5EED_5167_2026)
        var imported = 0, rejected = 0, slow = 0
        var worst = 0.0
        var s = SVGImportSettings()
        s.minimumSide = 0
        s.rasterize = false            // parser and layer builder are the targets; the system renderers are not ours to fuzz
        for i in 0..<count {
            autoreleasepool {
                var bytes = Array(corpus[Int.random(in: 0..<corpus.count, using: &rng)].utf8)
                let edits = Int.random(in: 1...3, using: &rng)
                for _ in 0..<edits where !bytes.isEmpty {
                    let at = Int.random(in: 0..<bytes.count, using: &rng)
                    switch Int.random(in: 0..<7, using: &rng) {
                    case 0: bytes.removeSubrange(at...)                                                     // truncate
                    case 1: bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...40, using: &rng)))
                    case 2: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + Int.random(in: 1...60, using: &rng))], at: at)
                    case 3: bytes[at] = UInt8.random(in: 0...255, using: &rng)
                    case 4: bytes.insert(contentsOf: Array(tokens[Int.random(in: 0..<tokens.count, using: &rng)].utf8), at: at)
                    case 5:
                        let other = Array(corpus[Int.random(in: 0..<corpus.count, using: &rng)].utf8)
                        bytes.insert(contentsOf: other[min(other.count, at)...].prefix(200), at: at)       // splice another file in
                    default:
                        let b = Int.random(in: 0..<bytes.count, using: &rng)
                        bytes.swapAt(at, b)
                    }
                }
                let t0 = CFAbsoluteTimeGetCurrent()
                // every 25th file also goes through the system renderers (what the serializer writes must not upset them)
                var cfg = s
                cfg.rasterize = i % 25 == 7
                if let r = try? SVGImport.load(data: Data(bytes), name: "fuzz-\(i).svg", settings: cfg) {
                    imported += 1
                    // what came out must also survive the compositor
                    if r.state.width * r.state.height <= 1_000_000 { _ = SVGImportQA.lumen(r.state) }
                } else { rejected += 1 }
                let dt = CFAbsoluteTimeGetCurrent() - t0
                worst = max(worst, dt)
                if dt > 5 { slow += 1; say("fuzz case \(i) took \(String(format: "%.1f", dt)) s") }
                if i % 25 == 24 { Compositor.shared.clearCaches() }
            }
        }
        Compositor.shared.clearCaches()
        check(imported + rejected == count && slow == 0, "fuzz: \(count) mutated files, \(imported) imported, \(rejected) rejected, none crashed or hung (slowest \(String(format: "%.2f", worst)) s)")
    }

    // MARK: Round trip through Lumen's exporters

    static func roundTrip(_ dir: URL) {
        let sheets = dir.appendingPathComponent("roundtrip")
        try? FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        func compare(_ name: String, _ original: DocumentState, _ svg: String, limit: Double = 1.0) -> DocumentState? {
            try? svg.write(to: sheets.appendingPathComponent(name + ".svg"), atomically: true, encoding: .utf8)
            guard let r = load(svg), let a = SVGImportQA.lumen(original), let b = SVGImportQA.lumen(r.state) else { check(false, "round trip \(name): imports"); return nil }
            let m = SVGImportQA.compare(a, b)
            SVGImportQA.sheet(a, b, to: sheets.appendingPathComponent(name + ".png"))
            check(r.state.width == original.width && r.state.height == original.height && m.mean <= limit && m.bad <= 0.01, "round trip \(name): exported SVG imports back looking the same (\(m.text)) — \(SVGImportQA.outline(r.state.layers))")
            return r.state
        }
        // WebExport's SVG export: shapes as paths, text as outlines or live text, gradients, strokes
        var st = WebExportSelfTest.vectorState()
        var star = ShapeContent(geometry: .polygon(CGRect(x: 250, y: 120, width: 90, height: 90), sides: 5, starRatio: 0.45), fill: .color(RGBA(hex: "F6AE2D")!))
        star.stroke = StrokeStyle(paint: .color(RGBA(hex: "1B1F3A")!), width: 3, alignment: .center, cap: .round, join: .round, dash: [3, 2])
        st.layers.append(Layer(name: "Star", content: .shape(star)))
        var ring = ShapeContent(geometry: .path(VectorPath(subpaths: VectorPath.ellipse(CGRect(x: 20, y: 140, width: 70, height: 70)).subpaths
                                                           + VectorPath.ellipse(CGRect(x: 40, y: 160, width: 30, height: 30)).withOperation(.subtract).subpaths)),
                                fill: .gradient(GradientFill(gradient: .twoColor(RGBA(hex: "2E86AB")!, RGBA(hex: "E94F37")!), type: .radial, angle: 0, scale: 1)))
        ring.stroke = StrokeStyle()
        var ringLayer = Layer(name: "Ring", content: .shape(ring))
        ringLayer.opacity = 0.8
        st.layers.append(ringLayer)
        var opt = SVGExportOptions()
        opt.mode = .vectorOnly
        if let back = compare("vector-outlines", st, SVGExport.export(st, options: opt).svg) {
            check(back.allLayers.filter(\.isShape).count == 6 && !back.allLayers.contains { $0.isRaster || $0.isText }, "round trip: every shape and the outlined text come back as shape layers (\(SVGImportQA.outline(back.layers)))")
            let fill = back.layers.first?.shape
            if case .rectangle? = fill?.geometry, case .color(let c)? = fill?.fill { check(c.hex == "F4F5F7", "round trip: the fill layer comes back as a live rectangle of the same colour") }
            else { check(false, "round trip: the fill layer comes back as a live rectangle") }
            let s2 = back.allLayers.first { $0.shape?.stroke.dash.isEmpty == false }?.shape?.stroke
            check(s2?.dash == [3, 2] && s2?.cap == .round && s2?.join == .round && abs((s2?.width ?? 0) - 3) < 1e-6, "round trip: stroke width, caps, joins and dash pattern survive (\(s2?.dash ?? []))")
            let g = back.allLayers.compactMap { l -> GradientFill? in if case .gradient(let g)? = l.shape?.fill { return g }; return nil }
            check(g.count == 2 && g.allSatisfy { $0.shape == nil } && g.contains { $0.type == .radial } && g.contains { $0.type == .linear }, "round trip: gradients come back as ordinary linear / radial gradients (\(g.count))")
            check(abs((back.allLayers.first { $0.opacity < 0.99 }?.opacity ?? 0) - 0.8) < 1e-6, "round trip: layer opacity survives")
        }
        opt.liveText = true
        if let back = compare("vector-live-text", st, SVGExport.export(st, options: opt).svg, limit: 1.6) {
            let t = back.allLayers.compactMap(\.text).first
            check(t?.text == "Lumen" && t?.fontName == "Helvetica-Bold" && abs((t?.fontSize ?? 0) - 44) < 1e-6 && t?.color.hex == "1B1F3A", "round trip: live text comes back as a text layer (\(t?.text ?? "nil"), \(t?.fontName ?? ""))")
        }
        // hybrid: pixel layers travel as embedded images
        let hy = WebExportSelfTest.hybridState()
        var hopt = SVGExportOptions()
        hopt.mode = .hybrid; hopt.rasterTarget = nil
        if let back = compare("hybrid", hy, SVGExport.export(hy, options: hopt).svg) {
            check(back.allLayers.contains { $0.isRaster } && back.allLayers.contains { $0.isShape }, "round trip: hybrid export comes back as pixel and shape layers (\(SVGImportQA.outline(back.layers)))")
        }
        // "Copy as SVG" of single layers, including inside / outside strokes (clip path and mask constructions)
        for (name, align) in [("center", StrokeAlignment.center), ("inside", .inside), ("outside", .outside)] {
            var sh = ShapeContent(geometry: .rectangle(CGRect(x: 30, y: 25, width: 120, height: 70), cornerRadius: 18), fill: .color(RGBA(hex: "8EC5FC")!))
            sh.stroke = StrokeStyle(paint: .color(RGBA(hex: "1B1F3A")!), width: 8, alignment: align)
            let svg = LayerSVGExport.svg(for: sh, name: "shape")
            guard let r = load(svg) else { check(false, "round trip copy-as-svg \(name): imports"); continue }
            // the exported box is the shape's own: compare with the shape moved to that origin
            let b = ShapeRenderer.docBounds(sh).insetBy(dx: 2, dy: 2).integral.insetBy(dx: -1, dy: -1)
            var ref = DocumentState(width: r.state.width, height: r.state.height)
            var moved = Layer(name: "s", content: .shape(sh))
            moved.translate(dx: Double(-b.minX), dy: Double(-b.minY))
            ref.layers = [moved]
            if let x = SVGImportQA.lumen(ref), let y = SVGImportQA.lumen(r.state) {
                let m = SVGImportQA.compare(x, y)
                SVGImportQA.sheet(x, y, to: sheets.appendingPathComponent("copy-\(name).png"))
                check(m.mean <= 0.8 && m.bad <= 0.01, "round trip: Copy as SVG with \(name) stroke imports back looking the same (\(m.text)) — \(SVGImportQA.outline(r.state.layers))")
            } else { check(false, "round trip copy-as-svg \(name): composites") }
        }
        Compositor.shared.clearCaches()
    }

    // MARK: App integration

    static func integration(_ dir: URL) {
        let work = dir.appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: work.appendingPathComponent("art"), withIntermediateDirectories: true)
        let ns = "xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'"
        func write(_ name: String, _ s: String) -> URL {
            let u = work.appendingPathComponent(name)
            try? s.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let app = AppModel.shared
        let docsBefore = app.documents.count

        // registration
        check(DocumentIO.customLoaders["svg"] != nil && DocumentIO.customLoaders["svgz"] != nil && DocumentIO.extraOpenTypes.contains(.svg) && DocumentIO.extraOpenTypes.contains(.pdf),
              "SVG is registered for Open / Place without displacing the other formats")
        check(SVGImportUI.unattended, "automated runs never show the import dialog")

        // File ▸ Open
        let badge = write("badge.svg", "<svg \(ns) width='120' height='80' viewBox='0 0 120 80'><title>Badge</title><rect id='plate' width='120' height='80' rx='10' fill='#1b1f3a'/><g id='mark'><circle cx='40' cy='40' r='22' fill='#e94f37'/><text x='70' y='47' font-family='Helvetica' font-size='20' fill='#fff'>Lu</text></g></svg>")
        do {
            let d = try DocumentIO.load(url: badge)
            check(d.state.width == 120 && d.state.height == 80 && d.fileURL == badge && SVGImportQA.outline(d.state.layers) == "shape, group[shape, text]", "File ▸ Open imports editable layers (\(SVGImportQA.outline(d.state.layers)))")
            check(d.state.layers.map(\.name) == ["plate", "mark"] && abs(d.state.resolution - 96) < 0.01, "layer names and resolution (\(d.state.layers.map(\.name)), \(d.state.resolution) ppi)")
            check(SVGImportReports.reports[d.id]?.shapes == 2 && SVGImportReports.reports[d.id]?.texts == 1 && app.statusMessage.contains("badge.svg"), "the import report is attached to the document and announced in the status bar (“\(app.statusMessage)”)")
            // the report is saved with the document
            let lumen = work.appendingPathComponent("badge.imagecrat")
            try DocumentIO.saveNative(d, to: lumen)
            let again = try DocumentIO.load(url: lumen)
            check(SVGImportReports.reports[again.id]?.text == SVGImportReports.reports[d.id]?.text && again.state.allLayers.count == d.state.allLayers.count, "the report travels in the .imagecrat file")
        } catch { check(false, "File ▸ Open: \(error.localizedDescription)") }
        // svgz
        let gzURL = work.appendingPathComponent("badge.svgz")
        try? gzip((try? Data(contentsOf: badge)) ?? Data()).write(to: gzURL)
        check((try? DocumentIO.load(url: gzURL))?.state.allLayers.count == 4, "compressed .svgz opens")
        // default size of tiny artwork, explicit sizes, flattened mode, white background
        let icon = write("icon.svg", "<svg \(ns) width='24' height='24' viewBox='0 0 24 24'><path d='M12 2 22 22H2z' fill='none' stroke='#222' stroke-width='2' stroke-linejoin='round'/></svg>")
        if let d = try? DocumentIO.load(url: icon) {
            let w = d.state.layers.first?.shape?.stroke.width ?? 0
            check(d.state.width == 264 && d.state.height == 264 && abs(w - 22) < 1e-6, "a 24 px icon opens at 11× with its stroke scaled (\(d.state.width) px, stroke \(w))")
        } else { check(false, "icon opens") }
        let saved = SVGImportUI.defaultSettings
        SVGImportUI.defaultSettings.width = 300; SVGImportUI.defaultSettings.height = 100
        SVGImportUI.defaultSettings.whiteBackground = true
        if let d = try? DocumentIO.load(url: badge) {
            check(d.state.width == 300 && d.state.height == 100 && d.state.layers.first?.name == "Background" && d.state.layers.first?.isRaster == true, "explicit size and white background (\(d.state.width)×\(d.state.height), \(SVGImportQA.outline(d.state.layers)))")
            check(d.state.allLayers.contains { $0.isShape } && d.state.allLayers.contains { $0.isText }, "a stretched import keeps its layers editable (\(SVGImportQA.outline(d.state.layers)))")
        } else { check(false, "sized import") }
        SVGImportUI.defaultSettings = saved
        SVGImportUI.defaultSettings.mode = .flattened
        if let d = try? DocumentIO.load(url: badge), let o = SVGImportQA.oracle((try? String(contentsOf: badge, encoding: .utf8)) ?? "", 120, 80), let l = SVGImportQA.lumen(d.state) {
            let m = SVGImportQA.compare(o, l)
            check(SVGImportQA.outline(d.state.layers) == "pixel" && m.mean < 0.05 && SVGImportReports.reports[d.id]?.flattened == true, "Flattened image: one pixel layer, identical to the system rendering (\(m.text))")
        } else { check(false, "flattened import") }
        SVGImportUI.defaultSettings = saved

        // images next to the file
        let pngData = Data(base64Encoded: String(SVGImportCorpus.png(16, 12).dropFirst("data:image/png;base64,".count))) ?? Data()
        try? pngData.write(to: work.appendingPathComponent("art/pic.png"))
        try? pngData.write(to: dir.appendingPathComponent("outside.png"))
        let withImages = write("images.svg", "<svg \(ns) width='120' height='40'><image x='4' y='4' width='16' height='12' href='art/pic.png'/><image x='30' y='4' width='32' height='24' xlink:href='art/pic.png'/><image x='0' y='0' width='10' height='10' href='../outside.png'/><image width='10' height='10' href='\(dir.appendingPathComponent("outside.png").path)'/></svg>")
        if let d = try? DocumentIO.load(url: withImages) {
            let rep = SVGImportReports.reports[d.id]
            check(SVGImportQA.outline(d.state.layers) == "pixel, smart" && rep?.items.filter { $0.kind == .ignored && $0.message.contains("could not be loaded") }.reduce(0) { $0 + $1.count } == 2,
                  "images beside the file load (pixel-exact → pixel layer, scaled → smart object); files outside its folder do not (\(SVGImportQA.outline(d.state.layers)))")
        } else { check(false, "images.svg opens") }

        // Place Embedded: a smart object holding the editable document, re-rendered from vectors when enlarged
        let host = Document.newBlank(width: 600, height: 400, background: .white, name: "host")
        let dot = write("dot.svg", "<svg \(ns) width='60' height='60' viewBox='0 0 60 60'><circle cx='30' cy='30' r='24' fill='#c03'/><text x='30' y='36' font-family='Helvetica' font-size='16' text-anchor='middle' fill='#fff'>Ab</text></svg>")
        FilesUI.withActive(host) { AppActions.place([dot], linked: false) }
        if let l = host.state.layers.last, case .document(let inner)? = l.smart?.source {
            check(SVGImportQA.outline(inner.layers) == "shape, text" && l.smart?.quad.bounds == CGRect(x: 270, y: 170, width: 60, height: 60), "Place Embedded makes a smart object whose contents are the editable SVG (\(SVGImportQA.outline(inner.layers)), \(l.smart?.quad.bounds ?? .zero))")
            // enlarge 8× and look at the circle's edge: a pixel enlargement would smear it over ~8 px
            var big = host.state
            big.updateLayer(l.id) { x in
                guard var so = x.smart else { return }
                so.quad = Quad(rect: CGRect(x: 60, y: -40, width: 480, height: 480))
                x.smart = so
            }
            Compositor.shared.clearCaches()
            if let cg = Compositor.shared.flatten(big, background: .white) {
                let b = PixelBuffer(cgImage: cg)
                // a row that cuts the circle at a slant (y = 80: 120 px above the centre), left half only
                var soft = 0, red = 0
                for x in 60..<300 {
                    let g = Int(b.pixel(x, 80).1)
                    if g > 8 && g < 247 { soft += 1 } else if g <= 8 { red += 1 }
                }
                check(red > 100 && soft >= 1 && soft <= 3, "an enlarged SVG smart object is re-rendered from its vectors: the slanted edge is \(soft) px wide at 8× (a pixel enlargement smears it over about 8)")
                SVGImportQA.writePNG(cg, dir.appendingPathComponent("placed-8x.png"))
            } else { check(false, "enlarged smart object composites") }
            // the 1:1 pixel path is untouched when nothing is enlarged
            check(SmartVectorScale.image(inner, quad: Quad(rect: CGRect(x: 0, y: 0, width: 60, height: 60)), composite: { _ in CIImage.clearImage }) == nil
                  && SmartVectorScale.image(inner, quad: Quad(rect: CGRect(x: 0, y: 0, width: 30, height: 30)), composite: { _ in CIImage.clearImage }) == nil, "smart objects shown at or below their own size keep the ordinary rendering")
            // Replace Contents
            let ok = AppActions.replaceSmartContents(of: l.id, in: host, with: badge)
            if case .document(let now)? = host.state.layer(l.id)?.smart?.source { check(ok && now.width == 120 && SVGImportQA.outline(now.layers) == "shape, group[shape, text]", "Replace Contents accepts an SVG") }
            else { check(false, "Replace Contents accepts an SVG") }
        } else { check(false, "Place Embedded makes a document smart object (\(SVGImportQA.outline(host.state.layers)))") }
        // Place Linked, and the automatic update when the file changes
        let linkedFile = write("linked.svg", "<svg \(ns) width='50' height='50'><rect width='50' height='50' fill='#00f'/></svg>")
        FilesUI.withActive(host) { AppActions.placeLinked(linkedFile) }
        if let l = host.state.layers.last, l.smart?.linkedURL == linkedFile {
            _ = write("linked.svg", "<svg \(ns) width='50' height='50'><rect width='50' height='50' fill='#0f0'/><circle cx='25' cy='25' r='10'/></svg>")
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: linkedFile.path)
            let n = AppActions.updateModifiedLinkedContent(host)
            if case .document(let now)? = host.state.layer(l.id)?.smart?.source { check(n == 1 && now.layers.count == 2, "Place Linked: the smart object follows the SVG file when it changes (\(n) updated, \(now.layers.count) layers)") }
            else { check(false, "Place Linked updates") }
        } else { check(false, "Place Linked makes a linked smart object") }

        // Paste: SVG markup on a private pasteboard
        let pb = NSPasteboard.withUniqueName()
        let realPB = AppActions.pasteboard
        AppActions.pasteboard = pb
        defer { AppActions.pasteboard = realPB; pb.releaseGlobally() }
        let markup = "<svg \(ns) width='90' height='60' viewBox='0 0 90 60'><rect width='90' height='60' rx='8' fill='#2e86ab'/><path d='M20 40 L45 15 L70 40' fill='none' stroke='#fff' stroke-width='6'/></svg>"
        pb.clearContents(); pb.setString(markup, forType: .string)
        let layersBefore = host.state.layers.count
        FilesUI.withActive(host) { AppActions.paste() }
        if host.state.layers.count == layersBefore + 1, case .document(let inner)? = host.state.layers.last?.smart?.source {
            check(SVGImportQA.outline(inner.layers) == "shape, shape" && host.state.layers.last?.name == "Pasted SVG", "pasting SVG text (Figma's Copy as SVG) places the editable artwork as a smart object")
        } else { check(false, "pasting SVG text places a smart object (\(SVGImportQA.outline(host.state.layers)))") }
        pb.clearContents(); pb.setData(Data(markup.utf8), forType: NSPasteboard.PasteboardType("public.svg-image"))
        let active = app.activeDocumentID
        app.activeDocumentID = nil
        AppActions.paste()
        if let nd = app.documents.last, nd.name == "Pasted SVG", app.documents.count == docsBefore + 1 {
            check(nd.state.width == 270 && SVGImportQA.outline(nd.state.layers) == "shape, shape", "pasting an SVG pasteboard flavour with no document open makes a new editable document (\(nd.state.width) px wide)")
            app.close(nd)
        } else { check(false, "pasting with no document open makes a new document") }
        app.activeDocumentID = active
        pb.clearContents(); pb.setString("just some <svg> text", forType: .string)
        check(!SVGImportUI.handlePaste(pb), "ordinary text on the pasteboard is left alone")
        pb.clearContents(); pb.setString("<svg xmlns='http://www.w3.org/2000/svg'><rect", forType: .string)
        check(SVGImportUI.svgData(on: pb) != nil, "damaged SVG text is still recognised as SVG")

        // the import dialog's size logic
        let dm = SVGImportDialogModel(natural: CGSize(width: 24, height: 12), initial: SVGImportSettings())
        let initial = (dm.width, dm.height)
        dm.setWidth(480)
        let locked = (dm.width, dm.height)
        dm.lock = false; dm.setHeight(100)
        let free = (dm.width, dm.height)
        dm.setScale(2)
        dm.mode = .flattened; dm.white = true
        check(initial == (264, 132) && locked == (480, 240) && free == (480, 100) && dm.settings.width == 48 && dm.settings.height == 24 && dm.lock && dm.settings.mode == .flattened && dm.settings.whiteBackground,
              "import dialog: default size, aspect lock, free size and scale presets (\(initial), \(locked), \(free))")

        // the report
        let rep = load("<svg \(ns) width='100' height='60'><defs><pattern id='p' width='6' height='6' patternUnits='userSpaceOnUse'><rect width='3' height='3'/></pattern></defs><rect id='Tiles' width='50' height='60' fill='url(#p)'/><text x='55' y='30' font-family='Definitely Missing' font-size='12'>Hi</text><rect x='60' y='40' width='20' height='10' style='display:none'/></svg>")?.report
        let text = rep?.text ?? ""
        check(text.contains("Rasterized") && text.contains("Pattern fill — “Tiles”") && text.contains("Missing fonts") && text.contains("“Definitely Missing” is not installed") && text.contains("1 text layer")
              && text.contains("hidden element"), "the report lists what stayed editable, what was rasterized and the substituted font")
        check(rep?.summary.contains("1 rasterized") == true && rep?.summary.contains("1 font substituted") == true && rep?.hasFindings == true, "status line summary (“\(rep?.summary ?? "")”)")
        try? text.write(to: dir.appendingPathComponent("sample-report.txt"), atomically: true, encoding: .utf8)
        // off the main thread WebKit cannot be used: the import still works through Core SVG
        var background: SVGImportResult?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            background = load("<svg \(ns) width='40' height='40'><defs><pattern id='p' width='6' height='6' patternUnits='userSpaceOnUse'><rect width='3' height='3' fill='#c03'/></pattern></defs><rect width='40' height='40' fill='url(#p)'/></svg>")
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + 20)
        check(waited == .success && background?.state.layers.first?.isRaster == true && background?.report.items.contains { $0.message.contains("Core SVG") } == true, "importing on a background thread falls back to Core SVG for rasterized pieces")
        // deep nesting on a secondary thread (512 KB of stack)
        var deep: SVGImportResult?
        DispatchQueue.global().async {
            deep = load("<svg \(ns) width='40' height='40'>" + String(repeating: "<g transform='translate(.1)' opacity='.99'><svg><a>", count: 60) + "<rect width='10' height='10'/>" + String(repeating: "</a></svg></g>", count: 60) + "</svg>")
            sem.signal()
        }
        check(sem.wait(timeout: .now() + 20) == .success && deep != nil, "deeply nested groups import on a background thread")

        app.documents.removeAll { $0 === host }
        check(app.documents.count == docsBefore, "no documents are left open by the tests")
        Compositor.shared.clearCaches()
    }
}
