import AppKit
import CoreText
import ImageCratCore

/// 4-character OpenType tags ↔ numeric ids (variation axes).
enum FontAxisTag {
    static func id(_ tag: String) -> UInt32 {
        if let n = UInt32(tag), tag.count > 4 { return n }
        var v: UInt32 = 0
        let bytes = Array(tag.utf8.prefix(4)) + Array(repeating: UInt8(32), count: max(0, 4 - tag.utf8.count))
        for b in bytes { v = (v << 8) | UInt32(b) }
        return v
    }

    static func string(_ id: UInt32) -> String {
        let b = [UInt8(id >> 24 & 255), UInt8(id >> 16 & 255), UInt8(id >> 8 & 255), UInt8(id & 255)]
        if b.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: b, encoding: .ascii) { return s }
        return String(id)
    }
}

/// A variable-font axis (CTFontCopyVariationAxes).
struct FontAxis: Identifiable, Equatable {
    var tag: String
    var name: String
    var min: Double
    var max: Double
    var defaultValue: Double
    var hidden: Bool
    var id: String { tag }

    private nonisolated(unsafe) static var cache: [String: [FontAxis]] = [:]
    private static let lock = NSLock()

    static func axes(fontName: String) -> [FontAxis] {
        lock.lock()
        if let c = cache[fontName] { lock.unlock(); return c }
        lock.unlock()
        let f = CTFontCreateWithName(fontName as CFString, 12, nil)
        var out: [FontAxis] = []
        if let arr = CTFontCopyVariationAxes(f) as? [[String: Any]] {
            for a in arr {
                guard let id = (a[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value,
                      let mn = (a[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                      let mx = (a[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue,
                      let df = (a[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue, mx > mn else { continue }
                let tag = FontAxisTag.string(id)
                let name = (a[kCTFontVariationAxisNameKey as String] as? String) ?? standardName(tag)
                let hidden = (a[kCTFontVariationAxisHiddenKey as String] as? NSNumber)?.boolValue ?? false
                out.append(FontAxis(tag: tag, name: name, min: mn, max: mx, defaultValue: df, hidden: hidden))
            }
        }
        lock.lock(); cache[fontName] = out; lock.unlock()
        return out
    }

    /// Default value of the font's named instance (e.g. 700 for "Montserrat-Bold"), else the axis default.
    static func currentValue(fontName: String, tag: String) -> Double? {
        let f = CTFontCreateWithName(fontName as CFString, 12, nil)
        guard let v = CTFontCopyVariation(f) as? [NSNumber: NSNumber] else { return nil }
        return v[NSNumber(value: FontAxisTag.id(tag))]?.doubleValue
    }

    static func standardName(_ tag: String) -> String {
        switch tag {
        case "wght": return "Weight"
        case "wdth": return "Width"
        case "slnt": return "Slant"
        case "ital": return "Italic"
        case "opsz": return "Optical Size"
        default: return tag
        }
    }
}

/// Closed path flattened to edges for scanline queries (area type).
struct AreaGeometry {
    private var edges: [(CGPoint, CGPoint)] = []
    let evenOdd: Bool
    let inset: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    /// Widest horizontal extent (inset applied).
    let maxWidth: CGFloat

    init?(_ a: AreaTextShape) {
        guard !a.path.isEmpty else { return nil }
        let (path, eo) = a.path.resolved
        evenOdd = eo
        inset = CGFloat(max(0, a.inset))
        var e: [(CGPoint, CGPoint)] = []
        var cur = CGPoint.zero, start = CGPoint.zero, open = false
        func close() { if open, cur.distance(to: start) > 1e-6 { e.append((cur, start)) }; open = false }
        path.applyWithBlock { el in
            let p = el.pointee
            switch p.type {
            case .moveToPoint:
                close()
                cur = p.points[0]; start = cur; open = true
            case .addLineToPoint:
                e.append((cur, p.points[0])); cur = p.points[0]
            case .addQuadCurveToPoint:
                let c = p.points[0], b = p.points[1], a0 = cur
                var prev = a0
                for i in 1...12 {
                    let u = CGFloat(i) / 12, v = 1 - u
                    let q = CGPoint(x: v * v * a0.x + 2 * v * u * c.x + u * u * b.x, y: v * v * a0.y + 2 * v * u * c.y + u * u * b.y)
                    e.append((prev, q)); prev = q
                }
                cur = b
            case .addCurveToPoint:
                let c1 = p.points[0], c2 = p.points[1], b = p.points[2], a0 = cur
                var prev = a0
                for i in 1...20 {
                    let u = CGFloat(i) / 20, v = 1 - u
                    let q = CGPoint(x: v * v * v * a0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * b.x,
                                    y: v * v * v * a0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * b.y)
                    e.append((prev, q)); prev = q
                }
                cur = b
            case .closeSubpath:
                close(); cur = start
            @unknown default: break
            }
        }
        close()
        guard !e.isEmpty else { return nil }
        edges = e
        let ys = e.flatMap { [$0.0.y, $0.1.y] }
        top = (ys.min() ?? 0) + inset
        bottom = (ys.max() ?? 0) - inset
        let xs = e.flatMap { [$0.0.x, $0.1.x] }
        maxWidth = max(0, (xs.max() ?? 0) - (xs.min() ?? 0) - 2 * inset)
    }

    /// Inside intervals of the scanline at `y`.
    func intervals(at y: CGFloat) -> [(lo: CGFloat, hi: CGFloat)] {
        var xs: [(CGFloat, Int)] = []
        for (a, b) in edges where a.y != b.y {
            if (a.y <= y && y < b.y) || (b.y <= y && y < a.y) {
                let x = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
                xs.append((x, b.y > a.y ? 1 : -1))
            }
        }
        xs.sort { $0.0 < $1.0 }
        var out: [(lo: CGFloat, hi: CGFloat)] = []
        var wind = 0, count = 0
        var startX: CGFloat = 0
        for (x, d) in xs {
            let wasIn = evenOdd ? count % 2 == 1 : wind != 0
            wind += d; count += 1
            let isIn = evenOdd ? count % 2 == 1 : wind != 0
            if !wasIn && isIn { startX = x } else if wasIn && !isIn, x > startX { out.append((startX, x)) }
        }
        return out
    }

    private static func intersect(_ a: [(lo: CGFloat, hi: CGFloat)], _ b: [(lo: CGFloat, hi: CGFloat)]) -> [(lo: CGFloat, hi: CGFloat)] {
        var out: [(lo: CGFloat, hi: CGFloat)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            let lo = max(a[i].lo, b[j].lo), hi = min(a[i].hi, b[j].hi)
            if hi > lo { out.append((lo, hi)) }
            if a[i].hi < b[j].hi { i += 1 } else { j += 1 }
        }
        return out
    }

    /// Widest horizontal span inside the shape for the whole band [top, bottom] (inset applied), at least `minWidth` wide.
    func widestInterval(top t: CGFloat, bottom b: CGFloat, minWidth: CGFloat) -> (lo: CGFloat, hi: CGFloat)? {
        guard b > t else { return nil }
        let samples = 6
        var acc: [(lo: CGFloat, hi: CGFloat)]? = nil
        for k in 0...samples {
            let y = t + (b - t) * CGFloat(k) / CGFloat(samples)
            let iv = intervals(at: min(max(y, t + 0.01), b - 0.01)).map { (lo: $0.lo + inset, hi: $0.hi - inset) }.filter { $0.hi > $0.lo }
            acc = acc.map { AreaGeometry.intersect($0, iv) } ?? iv
            if acc!.isEmpty { return nil }
        }
        guard let best = acc?.max(by: { ($0.hi - $0.lo) < ($1.hi - $1.lo) }), best.hi - best.lo >= minWidth else { return nil }
        return best
    }
}

extension TextRenderer {
    /// Dynamic Text readout: (font scale, extra tracking) the layout applies to fill the box.
    static func fitInfo(_ t: TextContent) -> (scale: CGFloat, tracking: Double)? {
        guard t.fitToBox != nil else { return nil }
        let L = layout(t)
        return (L.fitScale, L.fitTracking)
    }
}
