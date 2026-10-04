import Foundation
import CoreGraphics
import Compression
import ImageCratCore

// Byte-level PSD / PSB builder for the importer's self tests: writes the blocks Photoshop uses for type, shapes,
// adjustments, fills, smart objects, masks and the 16 / 32-bit and non-RGB variants. Test-only: it produces just
// enough of each structure for a reader, not files meant for Photoshop.

struct PSDTestLayer {
    var name = "Layer"
    var rect = IRect.zero
    /// 8-bit samples by channel id (0… colour, -1 transparency, -2 mask, -3 real user mask); widened to the file depth.
    var planes: [Int: [UInt8]] = [:]
    var blend = "norm"
    var opacity: UInt8 = 255
    var clipping: UInt8 = 0
    var flags: UInt8 = 8
    var mask = Data()
    var maskRect = IRect.zero
    var realMaskRect = IRect.zero
    var blendRanges = Data()
    var blocks: [(String, Data)] = []

    init(name: String = "Layer") { self.name = name }

    /// Pixel layer from a premultiplied RGBA buffer.
    init(name: String, buffer b: PixelBuffer, origin: IPoint) {
        self.name = name
        rect = IRect(x: origin.x, y: origin.y, width: b.width, height: b.height)
        let n = b.width * b.height
        var r = [UInt8](repeating: 0, count: n), g = r, bl = r, a = r
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<b.height { for x in 0..<b.width {
            let i = y * b.bytesPerRow + x * 4, o = y * b.width + x
            let al = Int(p[i + 3])
            a[o] = UInt8(al)
            func un(_ v: UInt8) -> UInt8 { al == 0 ? 0 : UInt8(min(255, (Int(v) * 255 + al / 2) / al)) }
            r[o] = un(p[i]); g[o] = un(p[i + 1]); bl[o] = un(p[i + 2])
        } }
        planes = [0: r, 1: g, 2: bl, -1: a]
    }

    mutating func add(_ key: String, _ d: Data) { blocks.append((key, d)) }

    /// Pixel (user) mask: rect + default colour + flags (bit 0 unlinked, bit 1 disabled), optional density / feather.
    mutating func setMask(_ r: IRect, _ samples: [UInt8], defaultColor: UInt8 = 0, flags f: UInt8 = 0, density: UInt8? = nil, feather: Double? = nil) {
        var w = BinaryWriter()
        w.i32(Int32(r.y)); w.i32(Int32(r.x)); w.i32(Int32(r.maxY)); w.i32(Int32(r.maxX))
        w.u8(defaultColor)
        let params = density != nil || feather != nil
        w.u8(f | (params ? 0x10 : 0))
        if params {
            w.u8((density != nil ? 1 : 0) | (feather != nil ? 2 : 0))
            if let d = density { w.u8(d) }
            if let fe = feather { w.u64(fe.bitPattern) }
            // real flags, background and rectangle repeat the user mask
            w.u8(f); w.u8(defaultColor)
            w.i32(Int32(r.y)); w.i32(Int32(r.x)); w.i32(Int32(r.maxY)); w.i32(Int32(r.maxX))
        } else {
            w.u16(0)
        }
        mask = w.data; maskRect = r
        planes[-2] = samples
    }

    /// Vector mask rendered by Photoshop into channel -2 (flag bit 3), optionally with a real pixel mask in channel -3.
    mutating func setRenderedVectorMask(_ r: IRect, _ samples: [UInt8], real: (IRect, [UInt8], UInt8)? = nil) {
        var w = BinaryWriter()
        w.i32(Int32(r.y)); w.i32(Int32(r.x)); w.i32(Int32(r.maxY)); w.i32(Int32(r.maxX))
        w.u8(0); w.u8(0x08)
        if let (rr, s, def) = real {
            w.u8(0); w.u8(def)
            w.i32(Int32(rr.y)); w.i32(Int32(rr.x)); w.i32(Int32(rr.maxY)); w.i32(Int32(rr.maxX))
            planes[-3] = s; realMaskRect = rr
        } else {
            w.u16(0)
        }
        mask = w.data; maskRect = r
        planes[-2] = samples
    }
}

struct PSDTestFile {
    var width: Int
    var height: Int
    var depth = 8
    var mode = 3
    var large = false
    /// 0 raw, 1 PackBits, 2 ZIP, 3 ZIP with prediction (layer channels).
    var compression = 1
    var mergedCompression = 1
    var colorModeData = Data()
    var resources: [(Int, String, Data)] = []
    var layers: [PSDTestLayer] = []
    var globalBlocks: [(String, Data)] = []
    /// Composite planes (8-bit samples, one per header channel).
    var merged: [[UInt8]] = []
    /// Put the layers in the 'Lr16' / 'Lr32' block as Photoshop does for deep files.
    var layersInBlock = false
    var negativeLayerCount = false

    init(width: Int, height: Int) { self.width = width; self.height = height }

    var colorChannels: Int { mode == 3 || mode == 9 ? 3 : (mode == 4 ? 4 : 1) }

    // MARK: Sample encoding

    static func srgbToLinear(_ v: UInt8) -> Float {
        let x = Double(v) / 255
        return Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
    }

    /// 8-bit samples → big-endian samples of the file depth (32-bit colour is linear light).
    func widen(_ s: [UInt8], color: Bool) -> [UInt8] {
        switch depth {
        case 16:
            var o = [UInt8](); o.reserveCapacity(s.count * 2)
            for v in s { o.append(v); o.append(v) }   // v * 257
            return o
        case 32:
            var o = [UInt8](); o.reserveCapacity(s.count * 4)
            for v in s {
                let f: Float = color ? PSDTestFile.srgbToLinear(v) : Float(v) / 255
                let b = f.bitPattern
                o.append(UInt8(b >> 24)); o.append(UInt8((b >> 16) & 0xff)); o.append(UInt8((b >> 8) & 0xff)); o.append(UInt8(b & 0xff))
            }
            return o
        default: return s
        }
    }

    static func adler32(_ d: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in d { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }

    static func deflate(_ d: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: d.count + d.count / 8 + 256)
        let n = d.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { o in
            compression_encode_buffer(o.baseAddress!, o.count, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
        } }
        let ad = adler32(d)
        return [0x78, 0x9C] + out.prefix(n) + [UInt8(ad >> 24), UInt8((ad >> 16) & 0xff), UInt8((ad >> 8) & 0xff), UInt8(ad & 0xff)]
    }

    /// Inverse of the reader's prediction step.
    func predict(_ d: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var o = d
        let bps = max(1, depth / 8), rb = w * bps
        for y in 0..<h {
            let base = y * rb
            switch depth {
            case 16:
                for x in stride(from: w - 1, to: 0, by: -1) {
                    let v = (Int(d[base + x * 2]) << 8 | Int(d[base + x * 2 + 1])) - (Int(d[base + (x - 1) * 2]) << 8 | Int(d[base + (x - 1) * 2 + 1]))
                    o[base + x * 2] = UInt8((v >> 8) & 0xff); o[base + x * 2 + 1] = UInt8(v & 0xff)
                }
            case 32:
                var planar = [UInt8](repeating: 0, count: rb)
                for x in 0..<w { for k in 0..<4 { planar[k * w + x] = d[base + x * 4 + k] } }
                for i in stride(from: rb - 1, to: 0, by: -1) { planar[i] = planar[i] &- planar[i - 1] }
                for i in 0..<rb { o[base + i] = planar[i] }
            default:
                for x in stride(from: rb - 1, to: 0, by: -1) { o[base + x] = d[base + x] &- d[base + x - 1] }
            }
        }
        return o
    }

    /// One channel: compression word + data.
    func channel(_ samples: [UInt8], width w: Int, height h: Int, color: Bool, compression comp: Int) -> Data {
        var out = BinaryWriter()
        if w <= 0 || h <= 0 || samples.isEmpty { out.u16(0); return out.data }
        let raw = widen(samples, color: color)
        let rb = w * max(1, depth / 8)
        out.u16(UInt16(comp))
        switch comp {
        case 1:
            var counts = BinaryWriter(), body = BinaryWriter()
            raw.withUnsafeBufferPointer { p in
                for y in 0..<h {
                    let e = PackBits.encode(UnsafeBufferPointer(rebasing: p[(y * rb)..<(y * rb + rb)]))
                    if large { counts.u32(UInt32(e.count)) } else { counts.u16(UInt16(e.count)) }
                    body.bytes(e)
                }
            }
            out.raw(counts.data); out.raw(body.data)
        case 2: out.bytes(PSDTestFile.deflate(raw))
        case 3: out.bytes(PSDTestFile.deflate(predict(raw, width: w, height: h)))
        default: out.bytes(raw)
        }
        return out.data
    }

    // MARK: File

    func layerInfo() -> Data {
        var li = BinaryWriter()
        li.i16(Int16(negativeLayerCount ? -layers.count : layers.count))
        var channelData = BinaryWriter()
        for l in layers {
            li.i32(Int32(l.rect.y)); li.i32(Int32(l.rect.x)); li.i32(Int32(l.rect.maxY)); li.i32(Int32(l.rect.maxX))
            var ids = Array(0..<colorChannels).filter { l.planes[$0] != nil || l.rect.isEmpty } + [-1].filter { l.planes[$0] != nil || l.rect.isEmpty }
            if l.planes[-2] != nil { ids.append(-2) }
            if l.planes[-3] != nil { ids.append(-3) }
            if l.rect.isEmpty { ids = [-1] + Array(0..<colorChannels) + ids.filter { $0 < -1 } }
            li.u16(UInt16(ids.count))
            var encoded: [Data] = []
            for id in ids {
                let r = id == -2 ? l.maskRect : (id == -3 ? l.realMaskRect : l.rect)
                let e = channel(l.planes[id] ?? [], width: r.width, height: r.height, color: id >= 0, compression: compression)
                encoded.append(e)
                li.i16(Int16(id)); li.len(e.count, large: large)
            }
            li.ascii("8BIM"); li.ascii(l.blend)
            li.u8(l.opacity); li.u8(l.clipping); li.u8(l.flags); li.u8(0)
            var extra = BinaryWriter()
            extra.u32(UInt32(l.mask.count)); extra.raw(l.mask)
            extra.u32(UInt32(l.blendRanges.count)); extra.raw(l.blendRanges)
            extra.pascal(String(l.name.prefix(31)), pad: 4)
            var luni = BinaryWriter(); luni.unicode(l.name)
            if luni.data.count % 4 != 0 { for _ in 0..<(4 - luni.data.count % 4) { luni.u8(0) } }
            extra.ascii("8BIM"); extra.ascii("luni"); extra.u32(UInt32(luni.data.count)); extra.raw(luni.data)
            for (key, payload) in l.blocks {
                var body = payload
                while body.count % 4 != 0 { body.append(0) }
                extra.ascii("8BIM"); extra.ascii(key); extra.len(body.count, large: large && PSDImporter.longKeys.contains(key)); extra.raw(body)
            }
            li.u32(UInt32(extra.data.count)); li.raw(extra.data)
            for e in encoded { channelData.raw(e) }
        }
        li.raw(channelData.data)
        while li.data.count % 4 != 0 { li.u8(0) }
        return li.data
    }

    func data() -> Data {
        var w = BinaryWriter()
        let channels = max(merged.count, colorChannels)
        w.ascii("8BPS"); w.u16(large ? 2 : 1); w.bytes([0, 0, 0, 0, 0, 0])
        w.u16(UInt16(channels)); w.u32(UInt32(height)); w.u32(UInt32(width)); w.u16(UInt16(depth)); w.u16(UInt16(mode))
        w.u32(UInt32(colorModeData.count)); w.raw(colorModeData)
        var res = BinaryWriter()
        for (id, name, body) in resources {
            res.ascii("8BIM"); res.u16(UInt16(id)); res.pascal(name, pad: 2); res.u32(UInt32(body.count)); res.raw(body)
            if body.count % 2 == 1 { res.u8(0) }
        }
        w.u32(UInt32(res.data.count)); w.raw(res.data)

        var lmi = BinaryWriter()
        let li = layerInfo()
        let inBlock = layersInBlock && !layers.isEmpty
        if layers.isEmpty || inBlock { lmi.len(0, large: large) } else { lmi.len(li.count, large: large); lmi.raw(li) }
        lmi.u32(0)   // global layer mask info
        var globals = globalBlocks
        if inBlock { globals.insert((depth == 32 ? "Lr32" : "Lr16", li), at: 0) }
        for (key, payload) in globals {
            var body = payload
            while body.count % 4 != 0 { body.append(0) }
            lmi.ascii("8BIM"); lmi.ascii(key); lmi.len(body.count, large: large && PSDImporter.longKeys.contains(key)); lmi.raw(body)
        }
        if layers.isEmpty && globals.isEmpty { w.len(0, large: large) } else { w.len(lmi.data.count, large: large); w.raw(lmi.data) }

        // image data: compression, then (RLE) all row counts, then the channels
        let rb = depth == 1 ? (width + 7) / 8 : width * max(1, depth / 8)
        w.u16(UInt16(mergedCompression))
        var counts = BinaryWriter(), body = BinaryWriter()
        for (i, p) in merged.enumerated() {
            let raw = depth == 1 ? p : widen(p, color: i < colorChannels)
            if mergedCompression == 1 {
                raw.withUnsafeBufferPointer { ptr in
                    for y in 0..<height {
                        let e = PackBits.encode(UnsafeBufferPointer(rebasing: ptr[(y * rb)..<(y * rb + rb)]))
                        if large { counts.u32(UInt32(e.count)) } else { counts.u16(UInt16(e.count)) }
                        body.bytes(e)
                    }
                }
            } else { body.bytes(raw) }
        }
        w.raw(counts.data); w.raw(body.data)
        return w.data
    }

    // MARK: Blocks

    static func u16(_ v: [Int]) -> Data { var w = BinaryWriter(); for x in v { w.i16(Int16(truncatingIfNeeded: x)) }; return w.data }

    static func versioned(_ d: PSDDescriptor, prefix: Data = Data()) -> Data { prefix + d.serializedVersioned() }

    static func colorDescriptor(_ c: RGBA) -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "RGBC", [("Rd  ", .double(c.r * 255)), ("Grn ", .double(c.g * 255)), ("Bl  ", .double(c.b * 255))]))
    }

    static func gradientDescriptor(_ g: ColorGradient) -> PSDDescriptorValue {
        let colors = g.sortedStops.map { s -> PSDDescriptorValue in
            .object(PSDDescriptor(classID: "Clrt", [("Clr ", colorDescriptor(s.color)), ("Type", .enumerated(type: "Clry", value: "UsrS")),
                                                   ("Lctn", .integer(Int32(s.location * 4096))), ("Mdpn", .integer(50))]))
        }
        let alphas = g.sortedStops.map { s -> PSDDescriptorValue in
            .object(PSDDescriptor(classID: "TrnS", [("Opct", .unitFloat(unit: "#Prc", value: s.color.a * 100)), ("Lctn", .integer(Int32(s.location * 4096))), ("Mdpn", .integer(50))]))
        }
        return .object(PSDDescriptor(classID: "Grdn", [("Nm  ", .string(g.name)), ("GrdF", .enumerated(type: "GrdF", value: "CstS")), ("Intr", .double(4096)),
                                                       ("Clrs", .list(colors)), ("Trns", .list(alphas))]))
    }

    static func solidFill(_ c: RGBA) -> Data { versioned(PSDDescriptor(classID: "null", [("Clr ", colorDescriptor(c))])) }

    static func gradientFillDescriptor(_ f: GradientFill, offset: CGPoint = .zero) -> PSDDescriptor {
        let types: [GradientType: String] = [.linear: "Lnr ", .radial: "Rdl ", .angle: "Angl", .reflected: "Rflc", .diamond: "Dmnd"]
        var items: [(String, PSDDescriptorValue)] = [
            ("Grad", gradientDescriptor(f.gradient)), ("Dthr", .bool(f.dither)), ("Rvrs", .bool(f.reverse)), ("Angl", .unitFloat(unit: "#Ang", value: f.angle)),
            ("Type", .enumerated(type: "GrdT", value: types[f.type] ?? "Lnr ")), ("Algn", .bool(true)), ("Scl ", .unitFloat(unit: "#Prc", value: f.scale * 100)),
        ]
        if offset != .zero {
            items.append(("Ofst", .object(PSDDescriptor(classID: "Pnt ", [("Hrzn", .unitFloat(unit: "#Prc", value: Double(offset.x))), ("Vrtc", .unitFloat(unit: "#Prc", value: Double(offset.y)))]))))
        }
        return PSDDescriptor(classID: "null", items)
    }

    static func patternFillDescriptor(id: String, name: String, scale: Double) -> PSDDescriptor {
        PSDDescriptor(classID: "null", [("Ptrn", .object(PSDDescriptor(classID: "Ptrn", [("Nm  ", .string(name)), ("Idnt", .string(id))]))),
                                        ("Scl ", .unitFloat(unit: "#Prc", value: scale * 100)), ("Algn", .bool(true))])
    }

    /// 'vmsk': version, flags, then 26-byte path records.
    static func vectorMask(_ p: VectorPath, width: Int, height: Int, flags: UInt32 = 0, ops: [Int]? = nil, startsFilled: Bool = false) -> Data {
        var w = BinaryWriter()
        w.u32(3); w.u32(flags)
        w.raw(pathRecords(p, width: width, height: height, ops: ops, startsFilled: startsFilled))
        return w.data
    }

    static func pathRecords(_ p: VectorPath, width: Int, height: Int, ops: [Int]? = nil, startsFilled: Bool = false) -> Data {
        var w = BinaryWriter()
        func pad(_ n: Int) { for _ in 0..<n { w.u8(0) } }
        func fixed(_ v: CGFloat, _ size: Int) -> Int32 { Int32((Double(v) / Double(size) * 16_777_216).rounded()) }
        w.u16(6); pad(24)
        w.u16(8); w.u16(startsFilled ? 1 : 0); pad(22)
        for (i, s) in p.subpaths.enumerated() {
            let op: Int
            if let ops, i < ops.count { op = ops[i] } else {
                switch s.operation { case .exclude: op = 0; case .combine: op = 1; case .subtract: op = 2; case .intersect: op = 3 }
            }
            w.u16(s.closed ? 0 : 3); w.u16(UInt16(s.points.count)); w.i16(Int16(op)); w.u16(1); w.u32(UInt32(i)); pad(14)
            for pt in s.points {
                w.u16(UInt16((s.closed ? 1 : 4) + (pt.isSmooth ? 0 : 1)))
                for q in [pt.inControl, pt.anchor, pt.outControl] { w.i32(fixed(q.y, height)); w.i32(fixed(q.x, width)) }
            }
        }
        return w.data
    }

    static func stroke(width: Double, color: RGBA, alignment: String = "strokeStyleAlignCenter", cap: String = "strokeStyleButtCap", join: String = "strokeStyleMiterJoin",
                       dash: [Double] = [], fillEnabled: Bool = true, enabled: Bool = true, opacity: Double = 100) -> Data {
        versioned(PSDDescriptor(classID: "strokeStyle", [
            ("strokeStyleVersion", .integer(2)), ("strokeEnabled", .bool(enabled)), ("fillEnabled", .bool(fillEnabled)),
            ("strokeStyleLineWidth", .unitFloat(unit: "#Pxl", value: width)), ("strokeStyleLineDashOffset", .unitFloat(unit: "#Pnt", value: 0)),
            ("strokeStyleMiterLimit", .double(100)), ("strokeStyleLineCapType", .enumerated(type: "strokeStyleLineCapType", value: cap)),
            ("strokeStyleLineJoinType", .enumerated(type: "strokeStyleLineJoinType", value: join)),
            ("strokeStyleLineAlignment", .enumerated(type: "strokeStyleLineAlignment", value: alignment)),
            ("strokeStyleScaleLock", .bool(false)), ("strokeStyleStrokeAdjust", .bool(false)),
            ("strokeStyleLineDashSet", .list(dash.map { .unitFloat(unit: "#Nne", value: $0) })),
            ("strokeStyleBlendMode", .enumerated(type: "BlnM", value: "Nrml")), ("strokeStyleOpacity", .unitFloat(unit: "#Prc", value: opacity)),
            ("strokeStyleContent", .object(PSDDescriptor(classID: "solidColorLayer", [("Clr ", colorDescriptor(color))]))),
            ("strokeStyleResolution", .double(72)),
        ]))
    }

    /// 'vogk': live-shape origination (1 rectangle, 2 rounded rectangle, 5 ellipse).
    static func origination(type: Int, rect r: CGRect, radius: Double? = nil) -> Data {
        var items: [(String, PSDDescriptorValue)] = [
            ("keyOriginType", .integer(Int32(type))), ("keyOriginResolution", .double(72)),
            ("keyOriginShapeBBox", .object(PSDDescriptor(classID: "unitRect", [("unitValueQuadVersion", .integer(1)), ("Top ", .unitFloat(unit: "#Pxl", value: Double(r.minY))),
                ("Left", .unitFloat(unit: "#Pxl", value: Double(r.minX))), ("Btom", .unitFloat(unit: "#Pxl", value: Double(r.maxY))), ("Rght", .unitFloat(unit: "#Pxl", value: Double(r.maxX)))]))),
        ]
        if let radius {
            let v = PSDDescriptorValue.unitFloat(unit: "#Pxl", value: radius)
            items.append(("keyOriginRRectRadii", .object(PSDDescriptor(classID: "radii", [("unitValueQuadVersion", .integer(1)), ("topRight", v), ("topLeft", v), ("bottomLeft", v), ("bottomRight", v)]))))
        }
        var w = BinaryWriter()
        w.u32(1)
        return w.data + versioned(PSDDescriptor(classID: "null", [("keyDescriptorList", .list([.object(PSDDescriptor(classID: "null", items))]))]))
    }

    // MARK: Type

    static func engineString(_ s: String) -> [UInt8] {
        var out: [UInt8] = [0x28, 0xFE, 0xFF]
        for u in s.utf16 {
            for b in [UInt8(u >> 8), UInt8(u & 0xff)] {
                if b == 0x28 || b == 0x29 || b == 0x5C { out.append(0x5C) }
                out.append(b)
            }
        }
        out.append(0x29)
        return out
    }

    struct TextRun {
        var length: Int
        var font = 0
        var size = 24.0
        var color = RGBA.black
        /// Extra `/Key value` pairs for the style sheet (e.g. "/FauxBold true /Tracking 50").
        var extra = ""
    }

    /// 'TySh' block. `text` uses "\r" between paragraphs (the trailing mark is added here).
    static func typeBlock(text: String, runs: [TextRun], fonts: [String], transform m: [Double], justification: Int = 0, box: CGRect? = nil, vertical: Bool = false,
                          paragraphExtra: String = "", warp: (String, Double, Double, Double)? = nil, damageEngineData: Bool = false) -> Data {
        var e: [UInt8] = []
        func put(_ s: String) { e += Array(s.utf8) }
        let full = text + "\r"
        let n = (full as NSString).length
        put("\n\n<<\n/EngineDict\n<<\n/Editor\n<<\n/Text "); e += engineString(full); put("\n>>\n")
        put("/ParagraphRun\n<<\n/DefaultRunData\n<<\n/ParagraphSheet\n<<\n/DefaultStyleSheet 0\n/Properties\n<<\n>>\n>>\n>>\n/RunArray [\n<<\n/ParagraphSheet\n<<\n/DefaultStyleSheet 0\n/Properties\n<<\n")
        put("/Justification \(justification)\n\(paragraphExtra)\n\(paragraphExtra.contains("/AutoLeading") ? "" : "/AutoLeading 1.2\n")>>\n>>\n>>\n]\n/RunLengthArray [ \(n) ]\n/IsJoinable 1\n>>\n")
        put("/StyleRun\n<<\n/DefaultRunData\n<<\n/StyleSheet\n<<\n/StyleSheetData\n<<\n>>\n>>\n>>\n/RunArray [\n")
        var lengths: [Int] = []
        for (i, r) in runs.enumerated() {
            put("<<\n/StyleSheet\n<<\n/StyleSheetData\n<<\n/Font \(r.font)\n/FontSize \(r.size)\n\(r.extra)\n/FillColor\n<<\n/Type 1\n/Values [ \(r.color.a) \(r.color.r) \(r.color.g) \(r.color.b) ]\n>>\n>>\n>>\n>>\n")
            lengths.append(r.length + (i == runs.count - 1 ? 1 : 0))   // the last run also covers the final paragraph mark
        }
        put("]\n/RunLengthArray [ \(lengths.map(String.init).joined(separator: " ")) ]\n/IsJoinable 2\n>>\n")
        put("/AntiAlias 4\n/UseFractionalGlyphWidths true\n/Rendered\n<<\n/Version 1\n/Shapes\n<<\n/WritingDirection \(vertical ? 2 : 0)\n/Children [\n<<\n/ShapeType \(box == nil ? 0 : 1)\n/Procession 0\n/Lines\n<<\n/WritingDirection \(vertical ? 2 : 0)\n/Children [ ]\n>>\n/Cookie\n<<\n/Photoshop\n<<\n/ShapeType \(box == nil ? 0 : 1)\n")
        if let b = box { put("/BoxBounds [ \(b.minX) \(b.minY) \(b.maxX) \(b.maxY) ]\n") } else { put("/PointBase [ 0.0 0.0 ]\n") }
        put("/Base\n<<\n/ShapeType \(box == nil ? 0 : 1)\n/TransformPoint0 [ 1.0 0.0 ]\n/TransformPoint1 [ 0.0 1.0 ]\n/TransformPoint2 [ 0.0 0.0 ]\n>>\n>>\n>>\n>>\n]\n>>\n>>\n>>\n")
        put("/ResourceDict\n<<\n/TheNormalStyleSheet 0\n/TheNormalParagraphSheet 0\n/ParagraphSheetSet [\n<<\n/DefaultStyleSheet 0\n/Properties\n<<\n/Justification 0\n/FirstLineIndent 0.0\n/StartIndent 0.0\n/EndIndent 0.0\n/SpaceBefore 0.0\n/SpaceAfter 0.0\n/AutoHyphenate true\n/AutoLeading 1.2\n>>\n>>\n]\n")
        put("/StyleSheetSet [\n<<\n/StyleSheetData\n<<\n/Font 0\n/FontSize 12.0\n/FauxBold false\n/FauxItalic false\n/AutoLeading true\n/Leading 0.0\n/HorizontalScale 1.0\n/VerticalScale 1.0\n/Tracking 0\n/AutoKerning true\n/Kerning 0\n/BaselineShift 0.0\n/FontCaps 0\n/FontBaseline 0\n/Underline false\n/Strikethrough false\n/Ligatures true\n/DLigatures false\n/FillColor\n<<\n/Type 1\n/Values [ 1.0 0.0 0.0 0.0 ]\n>>\n/FillFlag true\n/StrokeFlag false\n>>\n>>\n]\n")
        put("/FontSet [\n")
        for f in fonts { put("<<\n/Name "); e += engineString(f); put("\n/Script 0\n/FontType 0\n/Synthetic 0\n>>\n") }
        put("]\n/SuperscriptSize .583\n/SuperscriptPosition .333\n/SubscriptSize .583\n/SubscriptPosition .333\n/SmallCapSize .7\n>>\n>>")
        if damageEngineData { e = Array(e.prefix(e.count / 3)) }

        var w = BinaryWriter()
        w.u16(1)
        for v in m { w.u64(v.bitPattern) }
        w.u16(50)
        let td = PSDDescriptor(classID: "TxLr", [
            ("Txt ", .string(damageEngineData ? "" : text)), ("textGridding", .enumerated(type: "textGridding", value: "None")),
            ("Ornt", .enumerated(type: "Ornt", value: vertical ? "Vrtc" : "Hrzn")), ("AntA", .enumerated(type: "Annt", value: "AnCr")),
            ("TextIndex", .integer(0)), ("EngineData", .data(osType: "tdta", Data(e))),
        ])
        w.raw(td.serializedVersioned())
        w.u16(1)
        let wd = PSDDescriptor(classID: "warp", [
            ("warpStyle", .enumerated(type: "warpStyle", value: warp?.0 ?? "warpNone")), ("warpValue", .double(warp?.1 ?? 0)),
            ("warpPerspective", .double(warp?.2 ?? 0)), ("warpPerspectiveOther", .double(warp?.3 ?? 0)), ("warpRotate", .enumerated(type: "Ornt", value: "Hrzn")),
        ])
        w.raw(wd.serializedVersioned())
        for _ in 0..<4 { w.u32(0) }
        return w.data
    }

    // MARK: Smart objects

    static func smartObject(id: String, quad q: Quad, size: CGSize, warp: PSDDescriptor? = nil, filters: PSDDescriptor? = nil) -> Data {
        let v = [q.tl.x, q.tl.y, q.tr.x, q.tr.y, q.br.x, q.br.y, q.bl.x, q.bl.y].map { PSDDescriptorValue.double(Double($0)) }
        var items: [(String, PSDDescriptorValue)] = [
            ("Idnt", .string(id)), ("placed", .string(id + "-placed")), ("PgNm", .integer(1)), ("totalPages", .integer(1)), ("Annt", .integer(16)), ("Type", .integer(2)),
            ("Trnf", .list(v)), ("nonAffineTransform", .list(v)),
            ("warp", .object(warp ?? plainWarp(size))),
            ("Sz  ", .object(PSDDescriptor(classID: "Pnt ", [("Wdth", .double(Double(size.width))), ("Hght", .double(Double(size.height)))]))),
            ("Rslt", .unitFloat(unit: "#Rsl", value: 72)),
        ]
        if let f = filters { items.append(("filterFX", .object(f))) }
        var w = BinaryWriter()
        w.ascii("soLD"); w.u32(4)
        return w.data + versioned(PSDDescriptor(classID: "null", items))
    }

    static func warpBounds(_ size: CGSize) -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "Rctn", [("Top ", .unitFloat(unit: "#Pxl", value: 0)), ("Left", .unitFloat(unit: "#Pxl", value: 0)),
                                                ("Btom", .unitFloat(unit: "#Pxl", value: Double(size.height))), ("Rght", .unitFloat(unit: "#Pxl", value: Double(size.width)))]))
    }

    static func plainWarp(_ size: CGSize, style: String = "warpNone", value: Double = 0) -> PSDDescriptor {
        PSDDescriptor(classID: "warp", [("warpStyle", .enumerated(type: "warpStyle", value: style)), ("warpValue", .double(value)), ("warpPerspective", .double(0)),
                                        ("warpPerspectiveOther", .double(0)), ("warpRotate", .enumerated(type: "Ornt", value: "Hrzn")), ("bounds", warpBounds(size)),
                                        ("uOrder", .integer(4)), ("vOrder", .integer(4))])
    }

    /// Custom warp: 4 × 4 Bézier control points in source space (row by row).
    static func customWarp(_ size: CGSize, points: [CGPoint]) -> PSDDescriptor {
        var d = plainWarp(size, style: "warpCustom")
        let mesh = PSDDescriptor(classID: "rationalPoint", [("Hrzn", .unitFloats(unit: "#Pxl", values: points.map { Double($0.x) })),
                                                            ("Vrtc", .unitFloats(unit: "#Pxl", values: points.map { Double($0.y) }))])
        d["customEnvelopeWarp"] = .object(PSDDescriptor(classID: "customEnvelopeWarp", [("meshPoints", .objectArray(count: 16, mesh))]))
        return d
    }

    static func smartFilters(_ filters: [(name: String, cls: String, items: [(String, PSDDescriptorValue)], enabled: Bool)]) -> PSDDescriptor {
        let list = filters.map { f -> PSDDescriptorValue in
            .object(PSDDescriptor(classID: "filterFX", [
                ("Nm  ", .string(f.name)), ("enab", .bool(f.enabled)), ("hasoptions", .bool(true)),
                ("blendOptions", .object(PSDDescriptor(classID: "blendOptions", [("Opct", .unitFloat(unit: "#Prc", value: 100)), ("Md  ", .enumerated(type: "BlnM", value: "Nrml"))]))),
                ("Fltr", .object(PSDDescriptor(classID: f.cls, f.items))),
            ]))
        }
        return PSDDescriptor(classID: "filterFXStyle", [("enab", .bool(true)), ("validAtPosition", .bool(true)), ("filterMaskEnable", .bool(true)), ("filterFXList", .list(list))])
    }

    /// One 'lnk2' record: an embedded file ('liFD') or a reference to a file on disk ('liFE').
    static func link(id: String, name: String, data: Data? = nil, externalPath: String? = nil) -> Data {
        var e = BinaryWriter()
        e.ascii(data != nil ? "liFD" : "liFE"); e.u32(7)
        e.pascal(id, pad: 1); e.unicode(name)
        e.ascii("    "); e.ascii("    ")
        e.u64(UInt64(data?.count ?? 0))
        e.u8(0)
        if let path = externalPath {
            e.raw(PSDDescriptor(classID: "ExternalFileLink", [("descVersion", .integer(2)), ("Nm  ", .string(name)), ("fullPath", .string(path)), ("relPath", .string(name))]).serializedVersioned())
            e.u32(2026); e.u8(1); e.u8(1); e.u8(0); e.u8(0); e.u64(0)
            e.u64(0)
        }
        if let d = data { e.raw(d) }
        e.unicode(""); e.u64(0); e.u8(0)
        var w = BinaryWriter()
        w.u64(UInt64(e.data.count)); w.raw(e.data)
        while w.data.count % 4 != 0 { w.u8(0) }
        return w.data
    }

    // MARK: Patterns

    /// One entry of a 'Patt' block (RGB, 8 bit, PackBits).
    static func pattern(id: String, name: String, image b: PixelBuffer) -> Data {
        let w = b.width, h = b.height
        let l = PSDTestLayer(name: "", buffer: b, origin: .zero)
        var p = BinaryWriter()
        p.u32(1); p.u32(3); p.u16(UInt16(h)); p.u16(UInt16(w))
        p.unicode(name); p.pascal(id, pad: 1)
        var vm = BinaryWriter()
        vm.u32(0); vm.u32(0); vm.u32(UInt32(h)); vm.u32(UInt32(w)); vm.u32(24)
        for ch in 0..<26 {
            guard ch < 3, let plane = l.planes[ch] else { vm.u32(0); continue }
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
        p.u32(3); p.u32(UInt32(vm.data.count)); p.raw(vm.data)
        var out = BinaryWriter()
        out.u32(UInt32(p.data.count)); out.raw(p.data)
        while out.data.count % 4 != 0 { out.u8(0) }
        return out.data
    }
}
