import Foundation
import CoreGraphics
import ImageCratCore

// Vector data for export (the inverse of PSDVector): path records ('vmsk' and path resources), live-shape
// origination ('vogk'), fill content ('SoCo' / 'GdFl' / 'PtFl'), strokes ('vstk'), patterns ('Patt') and artboards.

enum PSDExportVector {
    typealias V = PSDDescriptorValue
    private static func fin(_ v: Double, _ d: Double = 0) -> Double { v.isFinite ? v : d }
    private static func px(_ v: Double) -> V { .unitFloat(unit: "#Pxl", value: fin(v)) }
    private static func pct(_ v: Double) -> V { .unitFloat(unit: "#Prc", value: fin(v)) }

    // MARK: Paths

    /// 26-byte path records: fill rule, initial fill, then per subpath a length record (with its Boolean operation)
    /// and its knots as (y, x) 8.24 fixed-point fractions of the canvas.
    static func pathRecords(_ p: VectorPath, width: Int, height: Int) -> Data {
        var w = BinaryWriter()
        func pad(_ n: Int) { for _ in 0..<n { w.u8(0) } }
        func fixed(_ v: CGFloat, _ size: Int) -> Int32 {
            let f = Double(v) / Double(max(1, size)) * 16_777_216
            return Int32(clamp(f.isFinite ? f : 0, -2_147_000_000, 2_147_000_000).rounded())
        }
        w.u16(6); pad(24)
        w.u16(8); w.u16(0); pad(22)
        var index: UInt32 = 0
        for s in p.subpaths where !s.points.isEmpty {
            let op: Int16
            switch s.operation { case .exclude: op = 0; case .combine: op = 1; case .subtract: op = 2; case .intersect: op = 3 }
            let pts = Array(s.points.prefix(65_000))
            w.u16(s.closed ? 0 : 3); w.u16(UInt16(pts.count)); w.i16(op); w.u16(1); w.u32(index); pad(14)
            index += 1
            for pt in pts {
                w.u16(UInt16((s.closed ? 1 : 4) + (pt.isSmooth ? 0 : 1)))
                for q in [pt.inControl, pt.anchor, pt.outControl] { w.i32(fixed(q.y, height)); w.i32(fixed(q.x, width)) }
            }
        }
        return w.data
    }

    /// 'vmsk': version 3, flags (bit 0 inverted, bit 1 not linked, bit 2 disabled), path records.
    static func vectorMaskBlock(_ p: VectorPath, width: Int, height: Int, disabled: Bool) -> Data {
        var w = BinaryWriter()
        w.u32(3); w.u32(disabled ? 4 : 0)
        w.raw(pathRecords(p, width: width, height: height))
        return w.data
    }

    // MARK: Live shapes

    /// 'vogk' for a rectangle, rounded rectangle or ellipse that is still axis-aligned (type 1, 2 or 5).
    static func origination(_ s: ShapeContent) -> Data? {
        let t = s.transform
        guard s.perspective == nil, abs(t.b) < 1e-9, abs(t.c) < 1e-9, t.a > 0, t.d > 0 else { return nil }
        let type: Int32
        var rect: CGRect
        var radius = 0.0
        switch s.geometry {
        case .rectangle(let r, let rad):
            rect = r.applying(t)
            radius = fin(rad)
            if radius > 0.01 {
                guard abs(t.a - t.d) < 1e-6 else { return nil }
                radius = min(radius * Double(t.a), Double(min(rect.width, rect.height)) / 2)
            }
            type = radius > 0.01 ? 2 : 1
        case .ellipse(let r):
            rect = r.applying(t)
            type = 5
        default: return nil
        }
        rect = rect.standardized
        guard rect.width > 0, rect.height > 0, [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite }) else { return nil }
        var items: [(String, V)] = [("keyOriginType", .integer(type))]
        if type != 5 {
            let r = px(radius)
            items.append(("keyOriginRRectRadii", .object(PSDDescriptor(classID: "radii", [("unitValueQuadVersion", .integer(1)), ("topRight", r), ("topLeft", r), ("bottomLeft", r), ("bottomRight", r)]))))
        }
        items.append(("keyOriginShapeBBox", .object(PSDDescriptor(classID: "unitRect", [
            ("unitValueQuadVersion", .integer(1)), ("Top ", px(Double(rect.minY))), ("Left", px(Double(rect.minX))),
            ("Btom", px(Double(rect.maxY))), ("Rght", px(Double(rect.maxX))),
        ]))))
        items.append(("keyOriginIndex", .integer(0)))
        var w = BinaryWriter()
        w.u32(1)
        return w.data + PSDDescriptor(classID: "null", [("keyDescriptorList", .list([.object(PSDDescriptor(classID: "null", items))]))]).serializedVersioned()
    }

    // MARK: Fill content

    static func color(_ c: RGBA) -> V { PSDExportAdjust.rgb(c) }

    static func gradientObject(_ g: ColorGradient) -> V {
        var stops = g.sortedStops.filter { $0.location.isFinite }
        if stops.isEmpty { stops = ColorGradient.twoColor(.black, .white).stops }
        let loc: (GradientStop) -> V = { .integer(Int32((clamp($0.location, 0, 1) * 4096).rounded())) }
        let clrs: [V] = stops.map { s in
            .object(PSDDescriptor(classID: "Clrt", [("Clr ", color(s.color)), ("Type", .enumerated(type: "Clry", value: "UsrS")), ("Lctn", loc(s)), ("Mdpn", .integer(50))]))
        }
        let trns: [V] = stops.map { s in
            .object(PSDDescriptor(classID: "TrnS", [("Opct", pct(clamp(fin(s.color.a, 1), 0, 1) * 100)), ("Lctn", loc(s)), ("Mdpn", .integer(50))]))
        }
        return .object(PSDDescriptor(classID: "Grdn", [("Nm  ", .string(g.name)), ("GrdF", .enumerated(type: "GrdF", value: "CstS")), ("Intr", .double(4096)),
                                                       ("Clrs", .list(clrs)), ("Trns", .list(trns))]))
    }

    static func gradientTypeKey(_ t: GradientType) -> String {
        switch t {
        case .linear: return "Lnr "
        case .radial: return "Rdl "
        case .angle: return "Angl"
        case .reflected: return "Rflc"
        case .diamond: return "Dmnd"
        }
    }

    /// Gradient settings relative to `refBounds` (the canvas for fill layers, the path for shapes). Explicit end
    /// points become angle, scale and offset.
    static func gradientItems(_ f: GradientFill, refBounds b: CGRect) -> ([(String, PSDDescriptorValue)], String?) {
        var angle = fin(f.angle, 90), scale = fin(f.scale, 1), offset = CGPoint.zero
        var note: String? = nil
        if let s = f.start, let e = f.end, b.width > 0, b.height > 0, [s.x, s.y, e.x, e.y].allSatisfy({ $0.isFinite }) {
            let d = CGPoint(x: e.x - s.x, y: e.y - s.y)
            let len = Double(hypot(d.x, d.y))
            if len > 1e-6 {
                angle = atan2(-Double(d.y), Double(d.x)) * 180 / .pi
                let rad = angle * .pi / 180
                let half1 = (abs(cos(rad)) * Double(b.width) + abs(sin(rad)) * Double(b.height)) / 2
                let linear = f.type == .linear
                scale = (linear ? len / 2 : len) / max(1e-6, half1)
                let c = linear ? CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2) : s
                offset = CGPoint(x: (c.x - b.midX) / b.width * 100, y: (c.y - b.midY) / b.height * 100)
            }
        }
        if f.activeShape != nil { note = "The gradient's imported shape (skew / focal point) is written as its angle and scale." }
        var items: [(String, PSDDescriptorValue)] = [
            ("Grad", gradientObject(f.gradient)),
            ("Angl", .unitFloat(unit: "#Ang", value: clamp(angle, -360, 360))),
            ("Type", .enumerated(type: "GrdT", value: gradientTypeKey(f.type))),
            ("Rvrs", .bool(f.reverse)),
            ("Dthr", .bool(f.dither)),
            ("Algn", .bool(true)),
            ("Scl ", pct(clamp(scale, 0.01, 100) * 100)),
        ]
        items.append(("Ofst", .object(PSDDescriptor(classID: "Pnt ", [("Hrzn", pct(Double(offset.x))), ("Vrtc", pct(Double(offset.y)))]))))
        return (items, note)
    }

    static func patternItems(_ id: String, scale: Double, ctx: PSDExportContext) -> ([(String, PSDDescriptorValue)], String?) {
        let def = PatternLibrary.pattern(id: id, custom: AppModel.shared.customPatterns)
        if def != nil { ctx.usePattern(id) }
        let items: [(String, PSDDescriptorValue)] = [
            ("Ptrn", .object(PSDDescriptor(classID: "Ptrn", [("Nm  ", .string(def?.name ?? id)), ("Idnt", .string(id))]))),
            ("Algn", .bool(true)),
            ("Scl ", pct(clamp(fin(scale, 1), 0.01, 10) * 100)),
            ("phase", .object(PSDDescriptor(classID: "Pnt ", [("Hrzn", .double(0)), ("Vrtc", .double(0))]))),
        ]
        return (items, def == nil ? "The pattern “\(id)” is not in the pattern library; Photoshop will report it missing." : nil)
    }

    struct Content {
        var block: (String, Data)
        var what: String
        var note: String?
    }

    /// 'SoCo' / 'GdFl' / 'PtFl' for a fill layer or a shape's fill.
    static func contentBlock(_ paint: PaintStyle, refBounds: CGRect, canvas: CGRect, ctx: PSDExportContext) -> Content {
        switch paint {
        case .none:
            return Content(block: ("SoCo", PSDDescriptor(classID: "null", [("Clr ", color(.black))]).serializedVersioned()), what: "no fill")
        case .color(let c):
            let note = c.a < 0.999 ? "The fill colour's opacity (\(Int((c.a * 100).rounded())) %) has no slot in Photoshop's solid colour; the colour is written opaque." : nil
            return Content(block: ("SoCo", PSDDescriptor(classID: "null", [("Clr ", color(c))]).serializedVersioned()), what: "solid colour", note: note)
        case .gradient(let f):
            let (items, note) = gradientItems(f, refBounds: refBounds.width > 0 && refBounds.height > 0 ? refBounds : canvas)
            return Content(block: ("GdFl", PSDDescriptor(classID: "null", items).serializedVersioned()), what: "\(f.type.displayName.lowercased()) gradient", note: note)
        case .pattern(let id, let scale):
            let (items, note) = patternItems(id, scale: scale, ctx: ctx)
            return Content(block: ("PtFl", PSDDescriptor(classID: "null", items).serializedVersioned()), what: "pattern", note: note)
        }
    }

    // MARK: Strokes

    static func strokeBlock(_ s: StrokeStyle, fillEnabled: Bool, ctx: PSDExportContext) -> (block: Data, note: String?) {
        let enabled = !s.paint.isNone && fin(s.width) > 0
        var note: String? = nil
        var opacity = 100.0
        let content: PSDDescriptor
        switch s.paint {
        case .none:
            content = PSDDescriptor(classID: "solidColorLayer", [("Clr ", color(.black))])
        case .color(let c):
            content = PSDDescriptor(classID: "solidColorLayer", [("Clr ", color(c))])
            opacity = clamp(fin(c.a, 1), 0, 1) * 100
        case .gradient(let f):
            let (items, n) = gradientItems(f, refBounds: .zero)
            content = PSDDescriptor(classID: "gradientLayer", items)
            note = n
        case .pattern(let id, let scale):
            let (items, n) = patternItems(id, scale: scale, ctx: ctx)
            content = PSDDescriptor(classID: "patternLayer", items)
            note = n
        }
        let align: String
        switch s.alignment {
        case .inside: align = "strokeStyleAlignInside"
        case .center: align = "strokeStyleAlignCenter"
        case .outside: align = "strokeStyleAlignOutside"
        }
        let cap: String
        switch s.cap {
        case .butt: cap = "strokeStyleButtCap"
        case .round: cap = "strokeStyleRoundCap"
        case .square: cap = "strokeStyleSquareCap"
        }
        let join: String
        switch s.join {
        case .miter: join = "strokeStyleMiterJoin"
        case .round: join = "strokeStyleRoundJoin"
        case .bevel: join = "strokeStyleBevelJoin"
        }
        // Dashes (shapesfills): Photoshop keeps dash / gap pairs in stroke widths, like Lumen. An odd-length pattern repeats,
        // so it is written doubled; dashes aligned to corners and patterns of more than six pairs are approximated.
        var dashSet = s.dash.count % 2 == 1 ? s.dash + s.dash : s.dash
        if dashSet.reduce(0, +) <= 0 { dashSet = [] }
        if dashSet.count > 12 {
            dashSet = Array(dashSet.prefix(12))
            note = [note, "The dash pattern has more than six dash / gap pairs; the first six are written."].compactMap { $0 }.joined(separator: " ")
        }
        if s.dashAlignment == .corners, !dashSet.isEmpty {
            note = [note, "Dashes aligned to corners are written as the plain dash pattern (Photoshop spaces them evenly)."].compactMap { $0 }.joined(separator: " ")
        }
        let d = PSDDescriptor(classID: "strokeStyle", [
            ("strokeStyleVersion", .integer(2)), ("strokeEnabled", .bool(enabled)), ("fillEnabled", .bool(fillEnabled)),
            ("strokeStyleLineWidth", px(clamp(fin(s.width), 0, 5000))),
            ("strokeStyleLineDashOffset", .unitFloat(unit: "#Pnt", value: clamp(fin(s.dashPhase ?? 0), -1000, 1000))),
            ("strokeStyleMiterLimit", .double(clamp(fin(s.miterLimit ?? 100, 100), 1, 1000))),
            ("strokeStyleLineCapType", .enumerated(type: "strokeStyleLineCapType", value: cap)),
            ("strokeStyleLineJoinType", .enumerated(type: "strokeStyleLineJoinType", value: join)),
            ("strokeStyleLineAlignment", .enumerated(type: "strokeStyleLineAlignment", value: align)),
            ("strokeStyleScaleLock", .bool(false)), ("strokeStyleStrokeAdjust", .bool(false)),
            ("strokeStyleLineDashSet", .list(dashSet.map { .unitFloat(unit: "#Nne", value: clamp(fin($0), 0, 1000)) })),
            ("strokeStyleBlendMode", .enumerated(type: "BlnM", value: "Nrml")),
            ("strokeStyleOpacity", pct(opacity)),
            ("strokeStyleContent", .object(content)),
            ("strokeStyleResolution", .double(72)),
        ])
        return (d.serializedVersioned(), note)
    }

    // MARK: Patterns

    /// 'Patt': every pattern a fill, shape or layer style refers to (RGB, 8 bit, PackBits; transparency in the
    /// user-mask slot).
    static func patternsBlock(_ ids: [String]) -> Data {
        var out = BinaryWriter()
        for id in ids {
            guard let def = PatternLibrary.pattern(id: id, custom: AppModel.shared.customPatterns) else { continue }
            let b = def.image
            let w = b.width, h = b.height
            guard w > 0, h > 0, w <= 4096, h <= 4096 else { continue }
            let pl = PSDExport.planes(b)
            let hasAlpha = pl[3].contains { $0 < 255 }
            var p = BinaryWriter()
            p.u32(1); p.u32(3); p.u16(UInt16(h)); p.u16(UInt16(w))
            p.unicode(def.name); p.pascal(id, pad: 1)
            var vm = BinaryWriter()
            vm.u32(0); vm.u32(0); vm.u32(UInt32(h)); vm.u32(UInt32(w)); vm.u32(24)
            func channel(_ plane: [UInt8]) {
                var c = BinaryWriter()
                c.u32(8); c.u32(0); c.u32(0); c.u32(UInt32(h)); c.u32(UInt32(w)); c.u16(8); c.u8(1)
                var counts = BinaryWriter(), body = BinaryWriter()
                plane.withUnsafeBufferPointer { ptr in
                    for y in 0..<h {
                        let e = PackBits.encode(UnsafeBufferPointer(rebasing: ptr[(y * w)..<(y * w + w)]))
                        counts.u16(UInt16(e.count)); body.bytes(e)
                    }
                }
                c.raw(counts.data); c.raw(body.data)
                vm.u32(1); vm.u32(UInt32(c.data.count)); vm.raw(c.data)
            }
            for ch in 0..<26 {
                if ch < 3 { channel(pl[ch]) } else if ch == 24 && hasAlpha { channel(pl[3]) } else { vm.u32(0) }
            }
            p.u32(3); p.u32(UInt32(vm.data.count)); p.raw(vm.data)
            out.u32(UInt32(p.data.count)); out.raw(p.data)
            while out.data.count % 4 != 0 { out.u8(0) }
        }
        return out.data
    }

    // MARK: Artboards

    static func artboard(_ a: Artboard) -> Data {
        let r = a.rect.standardized
        var items: [(String, V)] = [
            ("artboardRect", .object(PSDDescriptor(classID: "classFloatRect", [("Top ", .double(fin(Double(r.minY)))), ("Left", .double(fin(Double(r.minX)))),
                                                                              ("Btom", .double(fin(Double(r.maxY)))), ("Rght", .double(fin(Double(r.maxX))))]))),
            ("guideIndeces", .list([])),
            ("artboardPresetName", .string(a.presetName ?? "")),
        ]
        let type: Int32
        switch a.background {
        case nil: type = 3
        case .some(let c) where c.r > 0.999 && c.g > 0.999 && c.b > 0.999 && c.a > 0.999: type = 1
        case .some(let c) where c.r < 0.001 && c.g < 0.001 && c.b < 0.001 && c.a > 0.999: type = 2
        default: type = 4
        }
        items.append(("Clr ", color(a.background ?? .white)))
        items.append(("artboardBackgroundType", .integer(type)))
        return PSDDescriptor(classID: "null", items).serializedVersioned()
    }
}
