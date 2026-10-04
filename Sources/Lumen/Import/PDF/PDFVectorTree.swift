import Foundation
import CoreGraphics
import ImageCratCore

/// The display list arranged as the layer tree it will become: groups for optional-content layers, form XObjects
/// and clipping paths, leaves for the painted objects.
final class PDFVectorNode {
    enum Kind {
        case root
        case ocg(Int)
        case form(Int)
        case clip(Int)
        case item(Int)
    }
    var kind: Kind
    var children: [PDFVectorNode] = []

    init(_ kind: Kind) { self.kind = kind }

    var isClip: Bool { if case .clip = kind { return true }; return false }

    /// Groups consecutive items that share a container prefix.
    static func build(_ items: [PDFVectorItem]) -> PDFVectorNode {
        let root = PDFVectorNode(.root)
        var open: [(PDFVectorContext, PDFVectorNode)] = []
        for (i, it) in items.enumerated() {
            var common = 0
            while common < open.count, common < it.context.count, open[common].0 == it.context[common] { common += 1 }
            open.removeLast(open.count - common)
            for c in it.context[common...] {
                let node: PDFVectorNode
                switch c {
                case .ocg(let k): node = PDFVectorNode(.ocg(k))
                case .form(let k): node = PDFVectorNode(.form(k))
                case .clip(let k): node = PDFVectorNode(.clip(k))
                }
                (open.last?.1 ?? root).children.append(node)
                open.append((c, node))
            }
            (open.last?.1 ?? root).children.append(PDFVectorNode(.item(i)))
        }
        return root
    }

    /// Removes clip groups that clip nothing (a rectangle containing everything drawn inside it) and empty groups.
    /// `bounds` gives the extent of a leaf (nil = the leaf draws nothing and is dropped). Returns the node's extent.
    @discardableResult
    func simplify(clips: [PDFVectorClip], bounds: (Int) -> CGRect?) -> CGRect {
        var union = CGRect.null
        var out: [PDFVectorNode] = []
        for c in children {
            if case .item(let i) = c.kind {
                guard let b = bounds(i) else { continue }
                union = union.union(b)
                out.append(c)
                continue
            }
            let b = c.simplify(clips: clips, bounds: bounds)
            if c.children.isEmpty { continue }
            if case .clip(let k) = c.kind, let r = clips[k].rect, b.isNull || r.insetBy(dx: -0.75, dy: -0.75).contains(b) {
                out += c.children   // the rectangle holds all of its content
                union = union.union(b)
                continue
            }
            if case .clip(let k) = c.kind {
                let cb = b.intersection(clips[k].bounds)
                if cb.isNull || cb.isEmpty { continue }   // everything is clipped away
                union = union.union(cb)
            } else {
                union = union.union(b)
            }
            out.append(c)
        }
        children = out
        return union
    }

    var leafCount: Int {
        if case .item = kind { return 1 }
        return children.reduce(0) { $0 + $1.leafCount }
    }
}

/// Glyph outlines for text whose font is embedded in the PDF, and the pixel comparison used to check that a
/// reconstruction (editable text or outlines) really looks like the PDF's own rendering.
enum PDFVectorOutliner {
    struct Piece {
        var path: CGPath
        var fill: PDFVectorPaint
        var strokePaint: PDFVectorPaint
        var stroke: PDFVectorStroke?
    }

    /// Outlines of a text block in document space, one piece per change of paint. nil when a character has no
    /// glyph in the embedded font program (or there is no program).
    static func outlines(_ t: PDFVectorText) -> [Piece]? {
        guard t.positioned else { return nil }
        var out: [Piece] = []
        var cur: CGMutablePath? = nil
        var last: PDFVectorTextRun? = nil
        for r in t.runs {
            if let l = last, l.fill == r.fill, l.strokePaint == r.strokePaint, l.stroke == r.stroke, cur != nil {} else {
                if let c = cur, let l = last, !c.isEmpty { out.append(Piece(path: c, fill: l.fill, strokePaint: l.strokePaint, stroke: l.stroke)) }
                cur = CGMutablePath()
            }
            last = r
            let b = r.basis
            for g in r.glyphs {
                let (found, path) = r.font.outline(for: Int(g.code))
                guard found else { return nil }
                guard let path else { continue }
                let m = CGAffineTransform(a: b.a / 1000, b: b.b / 1000, c: b.c / 1000, d: b.d / 1000, tx: g.origin.x, ty: g.origin.y)
                cur?.addPath(path, transform: m)
            }
        }
        if let c = cur, let l = last, !c.isEmpty { out.append(Piece(path: c, fill: l.fill, strokePaint: l.strokePaint, stroke: l.stroke)) }
        return out
    }

    /// Bitmap (premultiplied RGBA, sRGB) covering document rect `r` at `zoom` pixels per document pixel, with a CTM
    /// that takes document coordinates (y down).
    static func context(_ r: CGRect, zoom: CGFloat = 1) -> CGContext? {
        let w = Int((r.width * zoom).rounded(.up)), h = Int((r.height * zoom).rounded(.up))
        guard w >= 1, h >= 1, w <= 16384, h <= 16384, w * h <= 64_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: zoom, y: -zoom)
        c.translateBy(x: -r.minX, y: -r.minY)
        return c
    }

    /// How differently two renderings of the same region are inked: 0 = the same shapes in the same colours,
    /// 1 = nothing in common. Both contexts are premultiplied RGBA of the same size. Coverage may differ by what a
    /// one-pixel shift of an edge explains (glyph rasterizers and path fills antialias and weight stems differently),
    /// so only ink that the other rendering does not have anywhere nearby counts.
    static func mismatch(_ a: CGContext, _ b: CGContext) -> Double {
        guard a.width == b.width, a.height == b.height, let da = a.data, let db = b.data else { return 1 }
        let pa = da.assumingMemoryBound(to: UInt8.self), pb = db.assumingMemoryBound(to: UInt8.self)
        let w = a.width, h = a.height, ra = a.bytesPerRow, rb = b.bytesPerRow
        var penalty = 0, ink = 0, colorDiff = 0, colorCount = 0
        for y in 0..<h {
            let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
            for x in 0..<w {
                let i = x * 4
                let va = Int(pa[y * ra + i + 3]), vb = Int(pb[y * rb + i + 3])
                if va == 0 && vb == 0 { continue }
                ink += max(va, vb)
                if va != vb {
                    let x0 = max(0, x - 1), x1 = min(w - 1, x + 1)
                    var minA = 255, maxA = 0, minB = 255, maxB = 0
                    for yy in y0...y1 {
                        for xx in x0...x1 {
                            let na = Int(pa[yy * ra + xx * 4 + 3]), nb = Int(pb[yy * rb + xx * 4 + 3])
                            if na < minA { minA = na }; if na > maxA { maxA = na }
                            if nb < minB { minB = nb }; if nb > maxB { maxB = nb }
                        }
                    }
                    if va > maxB { penalty += va - maxB } else if va < minB { penalty += minB - va }
                    if vb > maxA { penalty += vb - maxA } else if vb < minA { penalty += minA - vb }
                }
                if va > 200 && vb > 200 {
                    let o = y * ra + i, q = y * rb + i
                    colorDiff += abs(Int(pa[o]) - Int(pb[q])) + abs(Int(pa[o + 1]) - Int(pb[q + 1])) + abs(Int(pa[o + 2]) - Int(pb[q + 2]))
                    colorCount += 3
                }
            }
        }
        guard ink > 0 else { return 0 }
        let shape = Double(penalty) / Double(ink)
        let color = colorCount > 0 ? Double(colorDiff) / Double(colorCount * 255) : 0
        return shape + color
    }
}
