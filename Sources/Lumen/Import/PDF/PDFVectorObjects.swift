import Foundation
import CoreGraphics
import ImageCratCore

/// Typed accessors over the CGPDF object API. Every lookup resolves indirect references; nothing here can trap on
/// a damaged file (missing keys and wrong types come back as nil).
enum PDFVectorObj {
    /// Identity of a dictionary / stream / array: CG hands out one object per indirect reference, so the address
    /// tells shared resources apart from copies (used to write each object once and to stop reference cycles).
    static func id(_ d: CGPDFDictionaryRef) -> Int { unsafeBitCast(d, to: Int.self) }
    static func id(_ s: CGPDFStreamRef) -> Int { unsafeBitCast(s, to: Int.self) }

    static func object(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var o: CGPDFObjectRef? = nil
        return CGPDFDictionaryGetObject(d, key, &o) ? o : nil
    }
    static func dict(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var v: CGPDFDictionaryRef? = nil
        if CGPDFDictionaryGetDictionary(d, key, &v) { return v }
        // a stream where a dictionary is expected still has a usable dictionary (e.g. /SMask /G, function streams)
        if let s = stream(d, key) { return CGPDFStreamGetDictionary(s) }
        return nil
    }
    static func stream(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var v: CGPDFStreamRef? = nil
        return CGPDFDictionaryGetStream(d, key, &v) ? v : nil
    }
    static func array(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var v: CGPDFArrayRef? = nil
        return CGPDFDictionaryGetArray(d, key, &v) ? v : nil
    }
    static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var v: UnsafePointer<CChar>? = nil
        guard CGPDFDictionaryGetName(d, key, &v), let v else { return nil }
        return String(cString: v)
    }
    static func number(_ d: CGPDFDictionaryRef, _ key: String) -> Double? {
        var r: CGPDFReal = 0
        if CGPDFDictionaryGetNumber(d, key, &r) { return r.isFinite ? Double(r) : nil }
        return nil
    }
    static func int(_ d: CGPDFDictionaryRef, _ key: String) -> Int? {
        var i: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(d, key, &i) { return i }
        if let n = number(d, key), abs(n) < 1e15 { return Int(n) }
        return nil
    }
    static func bool(_ d: CGPDFDictionaryRef, _ key: String) -> Bool? {
        var b: CGPDFBoolean = 0
        return CGPDFDictionaryGetBoolean(d, key, &b) ? b != 0 : nil
    }
    static func string(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var s: CGPDFStringRef? = nil
        guard CGPDFDictionaryGetString(d, key, &s), let s else { return nil }
        return CGPDFStringCopyTextString(s) as String?
    }
    static func keys(_ d: CGPDFDictionaryRef) -> [String] {
        var out: [String] = []
        CGPDFDictionaryApplyBlock(d, { k, _, _ in out.append(String(cString: k)); return true }, nil)
        return out
    }

    static func numbers(_ a: CGPDFArrayRef?) -> [Double] {
        guard let a else { return [] }
        var out: [Double] = []
        let n = min(CGPDFArrayGetCount(a), 1 << 16)
        out.reserveCapacity(n)
        for i in 0..<n {
            var r: CGPDFReal = 0
            out.append(CGPDFArrayGetNumber(a, i, &r) && r.isFinite ? Double(r) : 0)
        }
        return out
    }
    static func numbers(_ d: CGPDFDictionaryRef, _ key: String) -> [Double] { numbers(array(d, key)) }

    static func objects(_ a: CGPDFArrayRef?) -> [CGPDFObjectRef] {
        guard let a else { return [] }
        var out: [CGPDFObjectRef] = []
        for i in 0..<min(CGPDFArrayGetCount(a), 1 << 16) {
            var o: CGPDFObjectRef? = nil
            if CGPDFArrayGetObject(a, i, &o), let o { out.append(o) }
        }
        return out
    }

    static func asDict(_ o: CGPDFObjectRef?) -> CGPDFDictionaryRef? {
        guard let o else { return nil }
        var d: CGPDFDictionaryRef? = nil
        if CGPDFObjectGetValue(o, .dictionary, &d) { return d }
        var s: CGPDFStreamRef? = nil
        if CGPDFObjectGetValue(o, .stream, &s), let s { return CGPDFStreamGetDictionary(s) }
        return nil
    }
    static func asStream(_ o: CGPDFObjectRef?) -> CGPDFStreamRef? {
        guard let o else { return nil }
        var s: CGPDFStreamRef? = nil
        return CGPDFObjectGetValue(o, .stream, &s) ? s : nil
    }
    static func asArray(_ o: CGPDFObjectRef?) -> CGPDFArrayRef? {
        guard let o else { return nil }
        var a: CGPDFArrayRef? = nil
        return CGPDFObjectGetValue(o, .array, &a) ? a : nil
    }
    static func asName(_ o: CGPDFObjectRef?) -> String? {
        guard let o else { return nil }
        var v: UnsafePointer<CChar>? = nil
        guard CGPDFObjectGetValue(o, .name, &v), let v else { return nil }
        return String(cString: v)
    }
    static func asNumber(_ o: CGPDFObjectRef?) -> Double? {
        guard let o else { return nil }
        var r: CGPDFReal = 0
        if CGPDFObjectGetValue(o, .real, &r) { return r.isFinite ? Double(r) : nil }
        var i: CGPDFInteger = 0
        if CGPDFObjectGetValue(o, .integer, &i) { return Double(i) }
        return nil
    }
    static func asBytes(_ o: CGPDFObjectRef?) -> [UInt8]? {
        guard let o else { return nil }
        var s: CGPDFStringRef? = nil
        guard CGPDFObjectGetValue(o, .string, &s), let s, let p = CGPDFStringGetBytePtr(s) else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s)))
    }

    /// Decoded stream bytes (nil when Core Graphics cannot decode the filter chain). `format` tells JPEG / JPEG 2000
    /// data apart, which is returned still compressed.
    static func data(_ s: CGPDFStreamRef) -> (Data, CGPDFDataFormat)? {
        var f = CGPDFDataFormat.raw
        guard let d = CGPDFStreamCopyData(s, &f) else { return nil }
        return (d as Data, f)
    }

    static func matrix(_ a: [Double]) -> CGAffineTransform? {
        guard a.count >= 6 else { return nil }
        return CGAffineTransform(a: a[0], b: a[1], c: a[2], d: a[3], tx: a[4], ty: a[5])
    }
    static func rect(_ a: [Double]) -> CGRect? {
        guard a.count >= 4 else { return nil }
        return CGRect(x: min(a[0], a[2]), y: min(a[1], a[3]), width: abs(a[2] - a[0]), height: abs(a[3] - a[1]))
    }

    /// Streams of a page's /Contents (or of a form XObject), decoded and joined with a newline between them
    /// (operators may not span streams, but operands and operators may be split across them).
    static func contentData(_ cs: CGPDFContentStreamRef, limit: Int) -> Data? {
        guard let arr = CGPDFContentStreamGetStreams(cs) else { return Data() }
        var out = Data()
        for i in 0..<CFArrayGetCount(arr) {
            guard let p = CFArrayGetValueAtIndex(arr, i) else { continue }
            let s = unsafeBitCast(p, to: CGPDFStreamRef.self)
            guard let (d, _) = data(s) else { continue }
            if out.count + d.count > limit { return nil }
            out.append(d)
            out.append(0x0A)
        }
        return out
    }
}
