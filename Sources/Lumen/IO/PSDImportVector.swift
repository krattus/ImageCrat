import Foundation
import CoreGraphics
import ImageCratCore

// Vector data: path records ('vmsk' / 'vsms' and path resources), fill content ('SoCo' / 'GdFl' / 'PtFl' / 'vscg'),
// strokes ('vstk'), live-shape origination ('vogk') and stored patterns ('Patt').

enum PSDVector {
    struct Mask {
        var path: VectorPath
        var inverted = false
        var unlinked = false
        var disabled = false
    }

    struct Paint {
        var paint: PaintStyle
        var what: String
        var notes: [String] = []
    }

    struct Stroke {
        var style: StrokeStyle
        var fillEnabled = true
        var notes: [String] = []
    }

    // MARK: Paths

    /// 26-byte path records → a path in document pixels. Knots are (y, x) pairs of 8.24 fixed point fractions of
    /// the canvas; each subpath starts with a length record carrying its Boolean operation.
    static func path(records c0: PSDCursor, width: Int, height: Int) -> (path: VectorPath, startsFilled: Bool) {
        var c = c0
        var out = VectorPath()
        var cur: Subpath? = nil
        var expected = 0
        var startsFilled = false
        let W = CGFloat(width), H = CGFloat(height)
        func flush() { if let s = cur, !s.points.isEmpty { out.subpaths.append(s) }; cur = nil }
        func fixed(_ v: Int) -> CGFloat { CGFloat(v) / 16_777_216 }
        while c.remaining >= 26, out.subpaths.count < 20000 {
            guard var rec = try? c.sub(26), let sel = try? rec.u16() else { break }
            switch sel {
            case 0, 3:
                flush()
                guard let n = try? rec.u16(), let op = try? rec.i16() else { break }
                expected = n
                var s = Subpath(points: [], closed: sel == 0)
                switch op {
                case 0: s.operation = .exclude
                case 1: s.operation = .combine
                case 2: s.operation = .subtract
                case 3: s.operation = .intersect
                // -1: another contour of the previous component (compound path): holes by the even-odd rule
                default: s.operation = out.subpaths.isEmpty ? .combine : .exclude
                }
                cur = s
            case 1, 2, 4, 5:
                guard cur != nil, (cur?.points.count ?? 0) < max(expected, 1) + 4 else { break }
                var v: [CGFloat] = []
                for _ in 0..<6 { if let x = try? rec.i32() { v.append(fixed(x)) } }
                guard v.count == 6 else { break }
                let p = PathPoint(anchor: CGPoint(x: v[3] * W, y: v[2] * H), inControl: CGPoint(x: v[1] * W, y: v[0] * H),
                                  outControl: CGPoint(x: v[5] * W, y: v[4] * H), isSmooth: sel == 1 || sel == 4)
                cur?.points.append(p)
            case 8:
                if let v = try? rec.u16(), v == 1 { startsFilled = true }
            default: break   // 6 fill rule, 7 clipboard
            }
        }
        flush()
        return (out, startsFilled)
    }

    /// The layer's vector mask ('vmsk', or 'vsms' in newer files).
    static func vectorMask(_ r: PSDRecord, _ imp: PSDImporter) -> Mask? {
        guard let b = r.block("vmsk") ?? r.block("vsms"), b.count >= 8 else { return nil }
        var c = PSDCursor(imp.bytes, b)
        guard let _ = try? c.u32(), let flags = try? c.u32() else { return nil }
        var (p, filled) = path(records: PSDCursor(imp.bytes, c.pos..<c.end), width: imp.W, height: imp.H)
        let inverted = flags & 1 != 0
        if (filled || inverted) && !p.isEmpty {
            // "everything, minus …": start from a rectangle well beyond the canvas
            let m = CGFloat(max(imp.W, imp.H))
            let all = VectorPath.rect(CGRect(x: -m, y: -m, width: CGFloat(imp.W) + 2 * m, height: CGFloat(imp.H) + 2 * m)).subpaths
            if inverted && !filled {
                // the inverse of a union is the surround minus every component (only exact for plain unions)
                if p.subpaths.allSatisfy({ $0.operation == .combine }) {
                    p.subpaths = all + p.subpaths.map { var s = $0; s.operation = .subtract; return s }
                } else {
                    p.subpaths = all.map { var s = $0; s.operation = .exclude; return s } + p.subpaths.map { var s = $0; s.operation = .exclude; return s }
                }
            } else if filled && !inverted {
                p.subpaths = all + p.subpaths
            }
        }
        return Mask(path: p, inverted: inverted, unlinked: flags & 2 != 0, disabled: flags & 4 != 0)
    }

    // MARK: Fill content

    static func color(_ d: PSDDescriptor?) -> RGBA? { PSDLayerStyle.parseColor(d?.object("Clr ")) }

    static func gradientFill(_ d: PSDDescriptor, canvas: CGSize) -> GradientFill? {
        guard let g = PSDLayerStyle.parseGradient(d.object("Grad")) else { return nil }
        var f = GradientFill(gradient: g)
        switch d.enumValue("Type") {
        case "Rdl "?: f.type = .radial
        case "Angl"?: f.type = .angle
        case "Rflc"?: f.type = .reflected
        case "Dmnd"?: f.type = .diamond
        default: f.type = .linear
        }
        func num(_ k: String, _ def: Double, _ lo: Double, _ hi: Double) -> Double { d.double(k).flatMap { $0.isFinite ? clamp($0, lo, hi) : nil } ?? def }
        f.angle = num("Angl", 90, -360, 360)
        f.scale = num("Scl ", 100, 1, 10000) / 100
        f.reverse = d.bool("Rvrs") ?? false
        f.dither = d.bool("Dthr") ?? false
        // an offset moves the whole gradient: express it with explicit end points
        if let o = d.object("Ofst"), let ox = o.double("Hrzn"), let oy = o.double("Vrtc"), ox.isFinite, oy.isFinite, ox != 0 || oy != 0 {
            let b = CGRect(origin: .zero, size: canvas)
            let (s, e) = f.endpoints(in: b)
            let shift = CGPoint(x: canvas.width * CGFloat(clamp(ox, -1000, 1000) / 100), y: canvas.height * CGFloat(clamp(oy, -1000, 1000) / 100))
            f.start = s + shift; f.end = e + shift
        }
        return f
    }

    static func paint(_ d: PSDDescriptor, _ imp: PSDImporter) -> Paint? {
        if d.object("Clr ") != nil, let c = color(d) { return Paint(paint: .color(c), what: "solid colour") }
        if d.object("Grad") != nil, let g = gradientFill(d, canvas: CGSize(width: imp.W, height: imp.H)) {
            var p = Paint(paint: .gradient(g), what: "\(g.type.displayName.lowercased()) gradient")
            if d.object("Grad")?.enumValue("GrdF") == "ClNs" { p.notes.append("Noise gradients are not supported; a black-to-white gradient is used.") }
            return p
        }
        if let pt = d.object("Ptrn") {
            let id = pt.string("Idnt") ?? ""
            let scale = (d.double("Scl ").flatMap { $0.isFinite ? clamp($0, 1, 1000) : nil } ?? 100) / 100
            if imp.patterns[id] != nil {
                imp.usePattern(id)
                return Paint(paint: .pattern(id: id, scale: scale), what: "pattern “\(pt.string("Nm  ") ?? id)”")
            }
            return Paint(paint: .pattern(id: "checker", scale: scale), what: "pattern",
                         notes: ["The pattern “\(pt.string("Nm  ") ?? id)” is not stored in the file; the checkerboard pattern is used instead."])
        }
        return nil
    }

    /// Content of a fill / shape layer, or nil when the record is not one.
    static func fillPaint(_ r: PSDRecord, _ imp: PSDImporter) -> Paint? {
        for key in ["SoCo", "GdFl", "PtFl"] {
            if let b = r.block(key), let d = imp.descriptor(b), let p = paint(d, imp) { return p }
        }
        if let b = r.block("vscg"), b.count > 8, let d = imp.descriptor(b, skip: 4), let p = paint(d, imp) { return p }
        return nil
    }

    // MARK: Stroke

    static func stroke(_ r: PSDRecord, _ imp: PSDImporter) -> Stroke? {
        guard let b = r.block("vstk"), let d = imp.descriptor(b) else { return nil }
        var out = Stroke(style: StrokeStyle())
        out.fillEnabled = d.bool("fillEnabled") ?? true
        guard d.bool("strokeEnabled") ?? false else { return out }
        var s = StrokeStyle()
        var w = d.double("strokeStyleLineWidth") ?? 1
        if d.unit("strokeStyleLineWidth") == "#Pnt", let res = d.double("strokeStyleResolution"), res.isFinite, res > 0 { w = w * res / 72 }
        s.width = w.isFinite ? clamp(w, 0, 5000) : 1
        switch d.enumValue("strokeStyleLineAlignment") {
        case "strokeStyleAlignInside"?: s.alignment = .inside
        case "strokeStyleAlignOutside"?: s.alignment = .outside
        default: s.alignment = .center
        }
        switch d.enumValue("strokeStyleLineCapType") {
        case "strokeStyleRoundCap"?: s.cap = .round
        case "strokeStyleSquareCap"?: s.cap = .square
        default: s.cap = .butt
        }
        switch d.enumValue("strokeStyleLineJoinType") {
        case "strokeStyleRoundJoin"?: s.join = .round
        case "strokeStyleBevelJoin"?: s.join = .bevel
        default: s.join = .miter
        }
        s.dash = (d.list("strokeStyleLineDashSet") ?? []).prefix(12).compactMap { $0.doubleValue.flatMap { $0.isFinite ? clamp($0, 0, 1000) : nil } }
        if s.dash.allSatisfy({ $0 == 0 }) { s.dash = [] }
        if let c = d.object("strokeStyleContent"), let p = paint(c, imp) {
            s.paint = p.paint
            out.notes += p.notes
        } else {
            s.paint = .color(.black)
        }
        if let o = d.double("strokeStyleOpacity"), o.isFinite, o < 99.5 {
            if case .color(var c) = s.paint { c.a *= clamp(o / 100, 0, 1); s.paint = .color(c) } else { out.notes.append("The stroke opacity (\(PSDImportReport.num(clamp(o, 0, 100))) %) only applies to solid colours.") }
        }
        if let m = d.enumValue("strokeStyleBlendMode"), m != "Nrml" { out.notes.append("The stroke's blend mode is not supported; it is drawn Normal.") }
        if s.width <= 0 { s.paint = .none }
        out.style = s
        return out
    }

    // MARK: Live shapes

    /// 'vogk' describes the primitive a path was drawn as. When the path still is that rectangle / ellipse
    /// (not rotated or edited), the shape stays a live primitive with editable size and corner radius.
    static func liveGeometry(_ r: PSDRecord, _ path: VectorPath, _ imp: PSDImporter) -> ShapeGeometry? {
        guard path.subpaths.count == 1, path.subpaths[0].closed, path.subpaths[0].operation != .subtract,
              let b = r.block("vogk"), b.count > 8, let d = imp.descriptor(b, skip: 4),
              let list = d.list("keyDescriptorList"), list.count == 1, let o = list[0].objectValue,
              let bb = o.object("keyOriginShapeBBox"), let t = bb.double("Top "), let l = bb.double("Left"), let bt = bb.double("Btom"), let rt = bb.double("Rght"),
              [t, l, bt, rt].allSatisfy({ $0.isFinite }), rt > l, bt > t else { return nil }
        let rect = CGRect(x: l, y: t, width: rt - l, height: bt - t)
        let candidate: ShapeGeometry
        switch PSDImportReport.int(o.double("keyOriginType")) ?? 0 {
        case 1: candidate = .rectangle(rect, cornerRadius: 0)
        case 2:
            guard let rr = o.object("keyOriginRRectRadii") else { return nil }
            let radii = ["topRight", "topLeft", "bottomLeft", "bottomRight"].compactMap { rr.double($0) }
            guard radii.count == 4, let first = radii.first, radii.allSatisfy({ abs($0 - first) < 0.01 }), first.isFinite, first >= 0 else { return nil }
            candidate = .rectangle(rect, cornerRadius: first)
        case 5: candidate = .ellipse(rect)
        default: return nil
        }
        // accept only when every anchor of the stored path sits on the primitive's outline
        let want = candidate.vectorPath.subpaths.first?.points.map(\.anchor) ?? []
        let have = path.subpaths[0].points.map(\.anchor)
        guard have.count == want.count, have.allSatisfy({ p in want.contains { $0.distance(to: p) < 1.0 } }) else { return nil }
        let pb = path.bounds
        guard abs(pb.minX - rect.minX) < 1, abs(pb.minY - rect.minY) < 1, abs(pb.maxX - rect.maxX) < 1, abs(pb.maxY - rect.maxY) < 1 else { return nil }
        return candidate
    }

    // MARK: Patterns

    /// 'Patt' / 'Pat2' / 'Pat3': a list of patterns, each a small image in a "virtual memory array list".
    static func patterns(_ c0: PSDCursor, into out: inout [String: PatternDef]) {
        var c = c0
        while c.remaining >= 16, out.count < 256 {
            guard let len = try? c.u32(), len >= 12, len <= c.remaining, var p = try? c.sub(len) else { break }
            let pad = (4 - len % 4) % 4
            if pad <= c.remaining { try? c.skip(pad) }
            if let def = pattern(&p) { out[def.id] = def }
        }
    }

    static func pattern(_ p: inout PSDCursor) -> PatternDef? {
        // image mode as in the file header; textures are usually single-channel (Grayscale or Multichannel)
        guard let version = try? p.u32(), version == 1, let mode = try? p.u32(), [1, 2, 3, 4, 7, 8, 9].contains(mode),
              (try? p.skip(4)) != nil, var name = try? p.unicode(), let id = try? p.pascal(pad: 1), !id.isEmpty else { return nil }
        // built-in presets carry a localisation key: "$$$/Patterns/Defaults/Watercolor=Watercolor"
        if name.hasPrefix("$$$"), let eq = name.lastIndex(of: "=") { name = String(name[name.index(after: eq)...]) }
        var palette: [UInt8] = []
        if mode == 2 {
            guard let r = try? p.take(768) else { return nil }
            palette = Array(p.bytes[r])
            try? p.skip(4)
        }
        guard let v = try? p.u32(), v == 3, let _ = try? p.u32(),
              let top = try? p.u32(), let left = try? p.u32(), let bottom = try? p.u32(), let right = try? p.u32(), let maxCh = try? p.u32() else { return nil }
        let w = right - left, h = bottom - top
        guard w > 0, h > 0, w <= 4096, h <= 4096, maxCh <= 64 else { return nil }
        var planes: [[UInt8]] = []
        for _ in 0..<(maxCh + 2) {
            guard p.remaining >= 4, let written = try? p.u32() else { break }
            if written == 0 { continue }
            guard let len = try? p.u32() else { break }
            if len == 0 { continue }
            guard len <= p.remaining, var ch = try? p.sub(len) else { break }
            guard let depth = try? ch.u32(), let ct = try? ch.u32(), let cl = try? ch.u32(), let cb = try? ch.u32(), let cr = try? ch.u32(),
                  (try? ch.skip(2)) != nil, let comp = try? ch.u8() else { continue }
            let cw = cr - cl, chh = cb - ct
            guard depth == 8, cw == w, chh == h else { continue }
            var plane = [UInt8](repeating: 0, count: w * h)
            if comp == 0 {
                guard let r = try? ch.take(min(w * h, ch.remaining)) else { continue }
                for (i, x) in ch.bytes[r].enumerated() { plane[i] = x }
            } else {
                var counts: [Int] = []
                for _ in 0..<h { guard let n = try? ch.u16() else { break }; counts.append(n) }
                guard counts.count == h else { continue }
                var pos = ch.pos
                ch.bytes.withUnsafeBufferPointer { src in plane.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let n = min(counts[y], max(0, ch.end - pos))
                        PSDImporter.unpackBits(src.baseAddress! + pos, n, dst.baseAddress! + y * w, w)
                        pos += n
                    }
                } }
            }
            planes.append(plane)
        }
        let conv = PSDColorConverter(mode: mode == 7 || mode == 8 ? 1 : mode, icc: nil, palette: palette)
        let colors = conv.colorChannels
        guard planes.count >= colors else { return nil }
        let rgb = conv.rgb(Array(planes.prefix(colors)), count: w * h, width: w, height: h)
        let buf = PSDImporter.rgba(width: w, height: h, r: rgb.0, g: rgb.1, b: rgb.2, a: planes.count > colors ? planes[colors] : nil)
        return PatternDef(id: id, name: name.isEmpty ? "Pattern" : name, image: buf)
    }
}
