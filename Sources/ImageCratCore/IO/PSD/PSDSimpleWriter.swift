import Foundation

// MARK: - Minimal portable PSD / PSB writer
//
// Writes a layered Photoshop file from straight RGBA pixels: pixel layers and groups (with blend mode, opacity,
// visibility and optional extra tagged blocks), plus the flattened composite. 8 or 16 bits per channel, RGB or
// grayscale, raw or PackBits (RLE). It exists for round-trip tests, the Windows self-check and synthetic test files;
// the Mac app's full exporter (Sources/Lumen/IO/PSDExport.swift) writes live text, shapes, smart objects etc.

package enum PSDSimpleWriter {
    package enum Compression { case raw, rle }
    package enum Mode { case rgb, grayscale }

    package struct Layer {
        package enum Kind { case pixels, groupStart, groupEnd }
        package var kind: Kind
        package var name: String
        /// Bounds on the canvas; `image` is `rect.width` × `rect.height`.
        package var rect: IRect
        package var image: RGBA8Image?
        package var blend: BlendMode
        package var opacity: UInt8
        package var hidden: Bool
        package var clipped: Bool
        /// Extra tagged blocks written after 'luni' (key, payload), e.g. 'lfx2' for a layer style.
        package var extraBlocks: [(String, Data)]

        package static func pixels(_ name: String, at origin: IPoint, _ image: RGBA8Image, blend: BlendMode = .normal,
                                   opacity: UInt8 = 255, hidden: Bool = false, clipped: Bool = false,
                                   extraBlocks: [(String, Data)] = []) -> Layer {
            Layer(kind: .pixels, name: name, rect: IRect(x: origin.x, y: origin.y, width: image.width, height: image.height), image: image,
                  blend: blend, opacity: opacity, hidden: hidden, clipped: clipped, extraBlocks: extraBlocks)
        }
        /// Opens a group: the layers that follow, up to the matching `groupEnd`, are inside it (top of stack first).
        package static func group(_ name: String, blend: BlendMode = .passThrough, opacity: UInt8 = 255, hidden: Bool = false, open: Bool = true) -> Layer {
            Layer(kind: .groupStart, name: name, rect: .zero, image: nil, blend: blend, opacity: opacity, hidden: hidden, clipped: false,
                  extraBlocks: open ? [] : [("__closed", Data())])
        }
        package static let groupEnd = Layer(kind: .groupEnd, name: "</Layer group>", rect: .zero, image: nil, blend: .normal, opacity: 255,
                                            hidden: false, clipped: false, extraBlocks: [])
    }

    /// `layers` are listed top of the stack first (as in the Layers panel). `composite` is the flattened picture
    /// (canvas size); with `compositeAlpha` its transparency is stored as the first extra channel.
    package static func write(width: Int, height: Int, layers: [Layer], composite: RGBA8Image, mode: Mode = .rgb, depth: Int = 8,
                              compression: Compression = .rle, compositeAlpha: Bool = true, resolution: Double = 72,
                              psb: Bool = false) -> Data {
        let depth = depth == 16 ? 16 : 8
        var w = BinaryWriter()
        let colorChannels = mode == .rgb ? 3 : 1
        let channels = colorChannels + (compositeAlpha ? 1 : 0)
        // header
        w.ascii("8BPS"); w.u16(psb ? 2 : 1); w.bytes([0, 0, 0, 0, 0, 0])
        w.u16(UInt16(channels)); w.u32(UInt32(height)); w.u32(UInt32(width)); w.u16(UInt16(depth)); w.u16(mode == .rgb ? 3 : 1)
        w.u32(0)   // colour mode data
        // image resources: resolution (1005)
        var res = BinaryWriter()
        res.ascii("8BIM"); res.u16(1005); res.u16(0)   // empty pascal name, padded to 2
        res.u32(16)
        let fixed = UInt32(max(1, min(65535, resolution)) * 65536)
        res.u32(fixed); res.u16(1); res.u16(2); res.u32(fixed); res.u16(1); res.u16(2)
        w.u32(UInt32(res.data.count)); w.raw(res.data)

        // layer info
        let li = layerInfo(layers.reversed(), colorChannels: colorChannels, depth: depth, compression: compression, psb: psb,
                           negativeCount: compositeAlpha)
        var lmi = BinaryWriter()
        if depth == 8 {
            lmi.len(li.count, large: psb); lmi.raw(li)
            lmi.u32(0)   // global mask info
        } else {
            // 16-bit documents keep the layers in an 'Lr16' tagged block
            lmi.len(0, large: psb)
            lmi.u32(0)
            lmi.ascii("8BIM"); lmi.ascii("Lr16"); lmi.len(li.count, large: psb); lmi.raw(li)
            while lmi.data.count % 4 != 0 { lmi.u8(0) }
        }
        w.len(lmi.data.count, large: psb); w.raw(lmi.data)

        // image data: the composite, colour channels then alpha
        var planes: [[UInt8]] = []
        let n = width * height
        var px = composite.pixels
        if px.count < n * 4 { px += [UInt8](repeating: 0, count: n * 4 - px.count) }
        if mode == .rgb {
            for k in 0..<3 { planes.append(matted(px, channel: k, count: n, alpha: compositeAlpha)) }
        } else {
            var g = [UInt8](repeating: 0, count: n)
            for i in 0..<n { g[i] = luma(px, i) }
            if compositeAlpha { for i in 0..<n { g[i] = overWhite(g[i], px[i * 4 + 3]) } }
            planes.append(g)
        }
        if compositeAlpha { planes.append((0..<n).map { px[$0 * 4 + 3] }) }
        switch compression {
        case .raw:
            w.u16(0)
            for p in planes { w.bytes(widen(p, depth: depth)) }
        case .rle:
            w.u16(1)
            var rows: [[UInt8]] = []
            for p in planes {
                let wide = widen(p, depth: depth)
                let rb = width * depth / 8
                for y in 0..<height { rows.append(wide.withUnsafeBufferPointer { PackBits.encode(UnsafeBufferPointer(rebasing: $0[(y * rb)..<((y + 1) * rb)])) }) }
            }
            for r in rows { if psb { w.u32(UInt32(r.count)) } else { w.u16(UInt16(r.count)) } }
            for r in rows { w.bytes(r) }
        }
        return w.data
    }

    /// Colour channel `channel` of straight RGBA pixels; with transparency it is matted on white as Photoshop stores it.
    private static func matted(_ px: [UInt8], channel k: Int, count n: Int, alpha: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = alpha ? overWhite(px[i * 4 + k], px[i * 4 + 3]) : px[i * 4 + k]
        }
        return out
    }

    /// Rec. 601 luma of pixel `i` of straight RGBA pixels.
    package static func luma(_ px: [UInt8], _ i: Int) -> UInt8 {
        let r = Int(px[i * 4]) * 77, g = Int(px[i * 4 + 1]) * 150, b = Int(px[i * 4 + 2]) * 29
        return UInt8(min(255, (r + g + b + 128) >> 8))
    }

    /// `v` with coverage `a` over white.
    package static func overWhite(_ v: UInt8, _ a: UInt8) -> UInt8 {
        let ai = Int(a)
        let sum = Int(v) * ai + 255 * (255 - ai)
        return UInt8((sum + 127) / 255)
    }

    /// 8-bit samples → big-endian samples of `depth` bits (16-bit: v × 257).
    private static func widen(_ p: [UInt8], depth: Int) -> [UInt8] {
        guard depth == 16 else { return p }
        var out = [UInt8](repeating: 0, count: p.count * 2)
        for i in 0..<p.count { out[i * 2] = p[i]; out[i * 2 + 1] = p[i] }   // v * 257 = (v << 8) | v
        return out
    }

    /// Layer info section body (layer count, records, channel data); `bottomFirst` is in file order.
    private static func layerInfo(_ bottomFirst: ReversedCollection<[Layer]>, colorChannels: Int, depth: Int, compression: Compression,
                                  psb: Bool, negativeCount: Bool) -> Data {
        let list = Array(bottomFirst)
        var w = BinaryWriter()
        let count = Int16(clamping: list.count)
        w.i16(negativeCount ? -count : count)
        var channelData: [[(id: Int16, data: [UInt8])]] = []
        for l in list {
            let r = l.kind == .pixels ? l.rect : IRect.zero
            var chans: [(id: Int16, data: [UInt8])] = []
            let ids: [Int16] = (0..<colorChannels).map { Int16($0) } + [-1]
            let n = r.width * r.height
            let px = l.image?.pixels ?? []
            for id in ids {
                var plane = [UInt8](repeating: 0, count: n)
                if n > 0, px.count >= n * 4 {
                    if id == -1 { for i in 0..<n { plane[i] = px[i * 4 + 3] } }
                    else if colorChannels == 3 { let k = Int(id); for i in 0..<n { plane[i] = px[i * 4 + k] } }
                    else { for i in 0..<n { plane[i] = luma(px, i) } }
                }
                chans.append((id, channel(plane, width: r.width, height: r.height, depth: depth, compression: compression, psb: psb)))
            }
            channelData.append(chans)
            // record
            w.i32(Int32(r.y)); w.i32(Int32(r.x)); w.i32(Int32(r.y + r.height)); w.i32(Int32(r.x + r.width))
            w.u16(UInt16(chans.count))
            for c in chans { w.i16(c.id); w.len(c.data.count, large: psb) }
            w.ascii("8BIM")
            let blendKey = l.kind == .groupEnd ? "norm" : (l.kind == .groupStart && l.blend == .passThrough ? "pass" : l.blend.psdKey)
            w.ascii(blendKey)
            w.u8(l.opacity); w.u8(l.clipped ? 1 : 0)
            var flags: UInt8 = 0x08   // bit 3: bit 4 is meaningful
            if l.hidden { flags |= 0x02 }
            if l.kind != .pixels { flags |= 0x10 }   // pixel data irrelevant to the appearance
            w.u8(flags); w.u8(0)
            var extra = BinaryWriter()
            extra.u32(0)   // no mask
            extra.u32(0)   // no blending ranges
            extra.pascal(l.name, pad: 4)
            var blocks: [(String, Data)] = []
            var uni = BinaryWriter(); uni.unicode(l.name); blocks.append(("luni", uni.data))
            switch l.kind {
            case .groupStart:
                var s = BinaryWriter()
                let closed = l.extraBlocks.contains { $0.0 == "__closed" }
                s.u32(closed ? 2 : 1); s.ascii("8BIM"); s.ascii(l.blend == .passThrough ? "pass" : l.blend.psdKey)
                blocks.append(("lsct", s.data))
            case .groupEnd:
                var s = BinaryWriter(); s.u32(3); blocks.append(("lsct", s.data))
            case .pixels: break
            }
            blocks += l.extraBlocks.filter { $0.0 != "__closed" }
            for (key, data) in blocks {
                extra.ascii("8BIM"); extra.ascii(key)
                var body = data
                while body.count % 2 != 0 { body.append(0) }
                extra.u32(UInt32(body.count)); extra.raw(body)
            }
            w.u32(UInt32(extra.data.count)); w.raw(extra.data)
        }
        for chans in channelData { for c in chans { w.bytes(c.data) } }
        while w.data.count % 2 != 0 { w.u8(0) }
        return w.data
    }

    /// One layer channel: compression word + data.
    private static func channel(_ plane: [UInt8], width: Int, height: Int, depth: Int, compression: Compression, psb: Bool) -> [UInt8] {
        var w = BinaryWriter()
        guard width > 0, height > 0 else { w.u16(0); return [UInt8](w.data) }
        let wide = widen(plane, depth: depth)
        let rb = width * depth / 8
        switch compression {
        case .raw:
            w.u16(0); w.bytes(wide)
        case .rle:
            w.u16(1)
            let rows = (0..<height).map { y in wide.withUnsafeBufferPointer { PackBits.encode(UnsafeBufferPointer(rebasing: $0[(y * rb)..<((y + 1) * rb)])) } }
            for r in rows { if psb { w.u32(UInt32(r.count)) } else { w.u16(UInt16(r.count)) } }
            for r in rows { w.bytes(r) }
        }
        return [UInt8](w.data)
    }
}
