import Foundation
import CoreGraphics
import ImageCratCore

/// Builds a scratch PDF whose pages replay chosen parts of a source page (one painting operator, a run of
/// operators, a colour swatch, a gradient ramp, an image at its native size, a soft-mask group) against copies of
/// the source's own resources. Rendering those pages with Core Graphics is how the importer gets pixels and
/// colours that are identical to what PDFKit shows for the page, without re-implementing colour spaces, image
/// codecs, patterns, mesh shadings or font rasterization.
final class PDFVectorWriter {
    enum Failure: Error { case tooLarge, unreadableStream }

    /// Serialized objects (object number = index + 1). nil while an object is being written (reserves the number).
    private var objects: [Data?] = []
    private var ids: [Int: Int] = [:]
    private var pages: [(box: CGRect, resources: Int, content: Int, group: Int?)] = []
    private(set) var byteCount = 0
    /// Hard stops for hostile or enormous files.
    var maxBytes = 1_200_000_000
    var maxObjects = 400_000
    private(set) var failed = false
    /// Extra catalog entries (" /OCProperties 12 0 R").
    var catalogEntries = ""

    var pageCount: Int { pages.count }

    // MARK: Objects

    private func reserve() -> Int { objects.append(nil); return objects.count }

    private func fill(_ n: Int, _ body: Data) {
        objects[n - 1] = body
        byteCount += body.count
        if byteCount > maxBytes || objects.count > maxObjects { failed = true }
    }

    /// Adds a synthesized object (dictionary text, no stream).
    @discardableResult
    func add(_ text: String) -> Int {
        let n = reserve()
        fill(n, Data(text.utf8))
        return n
    }

    /// Adds a synthesized stream object. `dict` holds the entries besides /Length (may be empty).
    @discardableResult
    func addStream(dict: String, data: Data) -> Int {
        let n = reserve()
        var d = Data("<< \(dict) /Length \(data.count) >>\nstream\n".utf8)
        d.append(data)
        d.append(Data("\nendstream".utf8))
        fill(n, d)
        return n
    }

    static func name(_ s: String) -> String {
        var out = "/"
        for c in s.utf8 {
            if c > 32 && c < 127 && c != 35 && c != 37 && c != 40 && c != 41 && c != 47 && c != 60 && c != 62 && c != 91 && c != 93 && c != 123 && c != 125 {
                out.unicodeScalars.append(UnicodeScalar(c))
            } else {
                out += String(format: "#%02X", c)
            }
        }
        return out
    }

    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func matrix(_ t: CGAffineTransform) -> String {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].map { number(Double($0)) }.joined(separator: " ")
    }

    /// Reference ("12 0 R") to a copy of a source dictionary.
    func ref(_ d: CGPDFDictionaryRef, depth: Int = 0) -> String {
        let key = PDFVectorObj.id(d)
        if let n = ids[key] { return "\(n) 0 R" }
        if failed || depth > 120 { return "null" }
        let n = reserve()
        ids[key] = n
        fill(n, Data(dictionaryText(d, skipping: [], depth: depth + 1).utf8))
        return "\(n) 0 R"
    }

    /// Reference to a copy of a source stream (decoded; JPEG / JPEG 2000 data stays compressed).
    func ref(_ s: CGPDFStreamRef, depth: Int = 0) -> String {
        let key = PDFVectorObj.id(s)
        if let n = ids[key] { return "\(n) 0 R" }
        if failed || depth > 120 { return "null" }
        let n = reserve()
        ids[key] = n
        guard let d = CGPDFStreamGetDictionary(s) else { fill(n, Data("null".utf8)); return "\(n) 0 R" }
        guard let (data, format) = PDFVectorObj.data(s) else {
            // Core Graphics cannot hand out this stream: a page that needs it must not pretend to match the source
            failed = true
            fill(n, Data("null".utf8))
            return "\(n) 0 R"
        }
        var extra = ""
        switch format {
        case .jpegEncoded: extra = " /Filter /DCTDecode" + lastDecodeParms(d, depth: depth + 1)
        case .JPEG2000: extra = " /Filter /JPXDecode"
        default: break
        }
        let text = dictionaryText(d, skipping: ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms", "DL"], depth: depth + 1, extra: extra + " /Length \(data.count)")
        var body = Data(text.utf8)
        body.append(Data("\nstream\n".utf8))
        body.append(data)
        body.append(Data("\nendstream".utf8))
        fill(n, body)
        return "\(n) 0 R"
    }

    /// /DecodeParms of the last filter (the JPEG colour transform flag survives the copy).
    private func lastDecodeParms(_ d: CGPDFDictionaryRef, depth: Int) -> String {
        if let p = PDFVectorObj.dict(d, "DecodeParms") { return " /DecodeParms " + dictionaryText(p, skipping: [], depth: depth) }
        if let a = PDFVectorObj.array(d, "DecodeParms"), let last = PDFVectorObj.objects(a).last, let p = PDFVectorObj.asDict(last) {
            return " /DecodeParms " + dictionaryText(p, skipping: [], depth: depth)
        }
        return ""
    }

    private func dictionaryText(_ d: CGPDFDictionaryRef, skipping: Set<String>, depth: Int, extra: String = "") -> String {
        var out = "<<"
        CGPDFDictionaryApplyBlock(d, { k, v, _ in
            let key = String(cString: k)
            if skipping.contains(key) { return true }
            out += " " + PDFVectorWriter.name(key) + " " + self.value(v, depth: depth)
            return !self.failed
        }, nil)
        return out + extra + " >>"
    }

    /// Inline text of any source value; dictionaries and streams become references.
    func value(_ o: CGPDFObjectRef, depth: Int = 0) -> String {
        if depth > 120 { return "null" }
        switch CGPDFObjectGetType(o) {
        case .null: return "null"
        case .boolean:
            var b: CGPDFBoolean = 0
            CGPDFObjectGetValue(o, .boolean, &b)
            return b != 0 ? "true" : "false"
        case .integer:
            var i: CGPDFInteger = 0
            CGPDFObjectGetValue(o, .integer, &i)
            return String(i)
        case .real:
            var r: CGPDFReal = 0
            CGPDFObjectGetValue(o, .real, &r)
            return PDFVectorWriter.number(Double(r))
        case .name:
            var n: UnsafePointer<CChar>? = nil
            CGPDFObjectGetValue(o, .name, &n)
            return n.map { PDFVectorWriter.name(String(cString: $0)) } ?? "null"
        case .string:
            var s: CGPDFStringRef? = nil
            guard CGPDFObjectGetValue(o, .string, &s), let s, let p = CGPDFStringGetBytePtr(s) else { return "()" }
            let n = min(CGPDFStringGetLength(s), 1 << 24)
            var out = "<"
            out.reserveCapacity(n * 2 + 2)
            let hex = Array("0123456789ABCDEF".utf8)
            for i in 0..<n {
                out.unicodeScalars.append(UnicodeScalar(hex[Int(p[i] >> 4)]))
                out.unicodeScalars.append(UnicodeScalar(hex[Int(p[i] & 15)]))
            }
            return out + ">"
        case .array:
            var a: CGPDFArrayRef? = nil
            guard CGPDFObjectGetValue(o, .array, &a), let a else { return "[]" }
            var out = "["
            let n = CGPDFArrayGetCount(a)
            for i in 0..<n {
                var e: CGPDFObjectRef? = nil
                if CGPDFArrayGetObject(a, i, &e), let e { out += " " + value(e, depth: depth + 1) } else { out += " null" }
                if failed { break }
            }
            return out + " ]"
        case .dictionary:
            var d: CGPDFDictionaryRef? = nil
            guard CGPDFObjectGetValue(o, .dictionary, &d), let d else { return "null" }
            return ref(d, depth: depth + 1)
        case .stream:
            var s: CGPDFStreamRef? = nil
            guard CGPDFObjectGetValue(o, .stream, &s), let s else { return "null" }
            return ref(s, depth: depth + 1)
        @unknown default: return "null"
        }
    }

    // MARK: Resources

    /// A resource dictionary for a scratch page: `source`'s entries restricted to the names in `used` (nil = all),
    /// plus synthesized entries (`extra[category][name]` = value text).
    func resources(from source: CGPDFDictionaryRef?, used: Set<String>?, extra: [String: [String: String]] = [:]) -> Int {
        var cats: [String: [String: String]] = extra
        if let source {
            CGPDFDictionaryApplyBlock(source, { k, v, _ in
                let cat = String(cString: k)
                guard let sub = PDFVectorObj.asDict(v) else { return true }
                CGPDFDictionaryApplyBlock(sub, { k2, v2, _ in
                    let name = String(cString: k2)
                    if let used, !used.contains(name) { return true }
                    if cats[cat]?[name] == nil { cats[cat, default: [:]][name] = self.value(v2, depth: 1) }
                    return !self.failed
                }, nil)
                return !self.failed
            }, nil)
        }
        var text = "<<"
        for (cat, entries) in cats.sorted(by: { $0.key < $1.key }) {
            text += " " + PDFVectorWriter.name(cat) + " <<"
            for (n, v) in entries.sorted(by: { $0.key < $1.key }) { text += " " + PDFVectorWriter.name(n) + " " + v }
            text += " >>"
        }
        return add(text + " >>")
    }

    // MARK: Pages

    /// Adds a page and returns its index. `group` is the source page's transparency group (blending colour space).
    @discardableResult
    func addPage(box: CGRect, resources: Int, content: Data, group: CGPDFDictionaryRef? = nil) -> Int {
        let c = addStream(dict: "", data: content)
        var g: Int? = nil
        if let group, case let r = ref(group), r.hasSuffix(" R"), let n = Int(r.split(separator: " ")[0]) { g = n }
        pages.append((box, resources, c, g))
        return pages.count - 1
    }

    /// The finished file, or nil when a limit was hit or a needed stream could not be copied.
    func finish() -> Data? {
        guard !failed, !pages.isEmpty else { return nil }
        let pagesObj = reserve()
        var kids: [Int] = []
        for p in pages {
            let b = p.box
            var t = "<< /Type /Page /Parent \(pagesObj) 0 R /MediaBox [\(PDFVectorWriter.number(b.minX)) \(PDFVectorWriter.number(b.minY)) \(PDFVectorWriter.number(b.maxX)) \(PDFVectorWriter.number(b.maxY))]"
            t += " /Resources \(p.resources) 0 R /Contents \(p.content) 0 R"
            if let g = p.group { t += " /Group \(g) 0 R" }
            kids.append(add(t + " >>"))
        }
        fill(pagesObj, Data("<< /Type /Pages /Count \(kids.count) /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] >>".utf8))
        let catalog = add("<< /Type /Catalog /Pages \(pagesObj) 0 R\(catalogEntries) >>")
        var out = Data()
        out.reserveCapacity(byteCount + objects.count * 40 + 256)
        out.append(Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8))
        var offsets: [Int] = []
        offsets.reserveCapacity(objects.count)
        for (i, body) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8))
            out.append(body ?? Data("null".utf8))
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(catalog) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }
}
