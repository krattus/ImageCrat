import Foundation

// MARK: - Portable PSD / PSB structure reader
//
// Reads what a viewer needs from a Photoshop file without any platform code: the header, a few image resources,
// the layer records (with their kind, blend mode, opacity, visibility, effects and the location of their channel
// data) and the flattened composite stored in the image data section. Pixels are decoded on demand, reduced to
// 8 bits per channel and returned as straight (not premultiplied) RGBA.
//
// Every read is bounds-checked: a damaged file gives an error or partial results, never a trap. The Mac app keeps
// its own importer (Sources/Lumen/IO/PSDImportCore.swift), which builds live layers; this one only describes them.

/// An 8-bit straight-alpha RGBA image (row-major, top row first, 4 bytes per pixel).
package struct RGBA8Image: Equatable {
    package var width: Int
    package var height: Int
    package var pixels: [UInt8]

    package init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Transparent image.
    package init(width: Int, height: Int) {
        self.width = max(0, width); self.height = max(0, height)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// Un-premultiplies a core `PixelBuffer` (RGBA premultiplied, or gray = opaque gray).
    package init(_ buf: PixelBuffer) {
        width = buf.width; height = buf.height
        var out = [UInt8](repeating: 0, count: buf.width * buf.height * 4)
        let s = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<buf.height {
            let row = s + y * buf.bytesPerRow
            for x in 0..<buf.width {
                let o = (y * buf.width + x) * 4
                if buf.format == .gray {
                    out[o] = row[x]; out[o + 1] = row[x]; out[o + 2] = row[x]; out[o + 3] = 255
                    continue
                }
                let a = Int(row[x * 4 + 3])
                out[o + 3] = UInt8(a)
                guard a > 0 else { continue }
                for k in 0..<3 { out[o + k] = UInt8(min(255, (Int(row[x * 4 + k]) * 255 + a / 2) / a)) }
            }
        }
        pixels = out
    }

    /// Premultiplied RGBA `PixelBuffer` (the core's format; `PNGCodec.encode` takes it).
    package func pixelBuffer() -> PixelBuffer {
        let buf = PixelBuffer(width: max(1, width), height: max(1, height))
        let d = buf.data.assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeBufferPointer { s in
            for y in 0..<height {
                let row = d + y * buf.bytesPerRow
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let a = Int(s[i + 3])
                    row[x * 4 + 3] = UInt8(a)
                    if a == 255 { row[x * 4] = s[i]; row[x * 4 + 1] = s[i + 1]; row[x * 4 + 2] = s[i + 2] }
                    else if a > 0 { for k in 0..<3 { row[x * 4 + k] = UInt8((Int(s[i + k]) * a + 127) / 255) } }
                }
            }
        }
        buf.markDirty()
        return buf
    }

    /// The pixel at (x, y) as (r, g, b, a); zeros outside the image.
    package func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    /// True when every pixel is fully opaque.
    package var isOpaque: Bool {
        var i = 3
        while i < pixels.count { if pixels[i] != 255 { return false }; i += 4 }
        return true
    }

    /// Box-filtered copy that fits in `maxSide` × `maxSide` (never enlarged).
    package func downscaled(maxSide: Int) -> RGBA8Image {
        guard width > 0, height > 0, maxSide > 0, max(width, height) > maxSide else { return self }
        let s = Double(maxSide) / Double(max(width, height))
        let w = max(1, Int((Double(width) * s).rounded())), h = max(1, Int((Double(height) * s).rounded()))
        return resampled(width: w, height: h, placing: IRect(x: 0, y: 0, width: width, height: height), canvasWidth: width, canvasHeight: height)
    }

    /// Box filter of this image placed at `rect` on a `canvasWidth` × `canvasHeight` canvas, into `width` × `height`
    /// (premultiplied averaging, so transparent pixels don't darken edges).
    package func resampled(width tw: Int, height th: Int, placing rect: IRect, canvasWidth cw: Int, canvasHeight ch: Int) -> RGBA8Image {
        var out = RGBA8Image(width: tw, height: th)
        guard tw > 0, th > 0, cw > 0, ch > 0, width > 0, height > 0 else { return out }
        var acc = [Int](repeating: 0, count: tw * th * 4)
        var cnt = [Int](repeating: 0, count: tw * th)
        // every canvas pixel maps to one target cell; count all canvas pixels of a cell so empty canvas stays transparent
        let sx = Double(tw) / Double(cw), sy = Double(th) / Double(ch)
        var colOf = [Int](repeating: 0, count: width)
        for x in 0..<width { colOf[x] = min(tw - 1, max(0, Int(Double(rect.x + x) * sx))) }
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<height {
                let cy = rect.y + y
                guard cy >= 0, cy < ch else { continue }
                let ty = min(th - 1, Int(Double(cy) * sy))
                for x in 0..<width {
                    let cx = rect.x + x
                    guard cx >= 0, cx < cw else { continue }
                    let i = (y * width + x) * 4
                    let a = Int(p[i + 3])
                    let c = ty * tw + colOf[x]
                    acc[c * 4] += Int(p[i]) * a; acc[c * 4 + 1] += Int(p[i + 1]) * a; acc[c * 4 + 2] += Int(p[i + 2]) * a; acc[c * 4 + 3] += a
                }
            }
        }
        // number of canvas pixels per cell (the denominator for alpha)
        var colCount = [Int](repeating: 0, count: tw)
        for x in 0..<cw { colCount[min(tw - 1, Int(Double(x) * sx))] += 1 }
        var rowCount = [Int](repeating: 0, count: th)
        for y in 0..<ch { rowCount[min(th - 1, Int(Double(y) * sy))] += 1 }
        for ty in 0..<th { for tx in 0..<tw { cnt[ty * tw + tx] = rowCount[ty] * colCount[tx] } }
        for c in 0..<(tw * th) {
            let a = acc[c * 4 + 3]
            guard a > 0, cnt[c] > 0 else { continue }
            out.pixels[c * 4] = UInt8(min(255, acc[c * 4] / a))
            out.pixels[c * 4 + 1] = UInt8(min(255, acc[c * 4 + 1] / a))
            out.pixels[c * 4 + 2] = UInt8(min(255, acc[c * 4 + 2] / a))
            out.pixels[c * 4 + 3] = UInt8(min(255, (a + cnt[c] / 2) / cnt[c]))
        }
        return out
    }
}

/// What a layer record is, as far as a viewer can tell from its tagged blocks.
package enum PSDLayerKind: String, CaseIterable {
    case pixel, text, shape, smartObject, adjustment, fill, group, artboard

    package var displayName: String {
        switch self {
        case .pixel: return "Pixel"
        case .text: return "Text"
        case .shape: return "Shape"
        case .smartObject: return "Smart object"
        case .adjustment: return "Adjustment"
        case .fill: return "Fill"
        case .group: return "Group"
        case .artboard: return "Artboard"
        }
    }
}

/// One entry of the Layers list, top of the stack first.
package struct PSDLayerSummary {
    package var name: String
    /// Group nesting (0 = top level).
    package var depth: Int
    package var kind: PSDLayerKind
    /// Extra detail for the kind ("Levels", "Solid color", …); empty when there is none.
    package var kindDetail: String
    package var isVisible: Bool
    package var blendKey: String
    package var blendMode: BlendMode
    /// 0…1
    package var opacity: Double
    /// Fill opacity ('iOpa'), 0…1; nil when the file has none.
    package var fillOpacity: Double?
    package var isClipped: Bool
    package var hasMask: Bool
    package var hasVectorMask: Bool
    /// Names of the enabled layer effects, Photoshop's panel order.
    package var effects: [String]
    /// False when the style's master switch ("Effects" eye) is off.
    package var effectsVisible: Bool
    /// Pixel bounds of the layer's stored pixels, in canvas coordinates.
    package var rect: IRect
    /// Index into `PSDFile.records` (bottom = 0, as stored).
    package var recordIndex: Int
}

package enum PSDColorMode {
    package static func name(_ mode: Int) -> String {
        switch mode {
        case 0: return "Bitmap"
        case 1: return "Grayscale"
        case 2: return "Indexed"
        case 3: return "RGB"
        case 4: return "CMYK"
        case 7: return "Multichannel"
        case 8: return "Duotone"
        case 9: return "Lab"
        default: return "Mode \(mode)"
        }
    }
}

/// A parsed Photoshop document. Construction reads the structure; pixels are decoded by `composite()`,
/// `layerImage(_:)` and `layerThumbnail(_:maxSide:)`.
package final class PSDFile: PSDByteSource {
    package let bytes: [UInt8]
    package private(set) var isPSB = false
    package private(set) var width = 0
    package private(set) var height = 0
    package private(set) var depth = 8
    package private(set) var colorMode = 3
    package private(set) var channelCount = 3
    /// Pixels per inch (resource 1005); nil when the file doesn't say.
    package private(set) var resolution: Double? = nil
    package private(set) var iccProfileSize = 0
    package private(set) var records: [PSDRecord] = []
    /// Channel data of each record: (channel id, byte range of compression word + data).
    package private(set) var channelRanges: [[(id: Int, range: Range<Int>)]] = []
    /// Problems found while reading (the file still opened).
    package private(set) var warnings: [String] = []
    package private(set) var layers: [PSDLayerSummary] = []
    /// The negative layer count flag: the composite's first extra channel is its transparency.
    package private(set) var mergedHasTransparency = false
    private var alphaNames: [String] = []
    private var palette: [UInt8] = []
    private var transparentIndex: Int? = nil
    private var imageDataStart: Int? = nil

    /// Parses `data`. Throws when the header is not a readable Photoshop header; damage after it ends up in `warnings`.
    package convenience init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    package init(bytes: [UInt8]) throws {
        self.bytes = bytes
        var c = PSDCursor(bytes)
        try header(&c)
        // colour mode data
        let cmLen = try c.u32()
        let cm = try c.take(min(cmLen, c.remaining))
        if cmLen > cm.count { warnings.append("The file ends inside the colour mode data.") }
        if colorMode == 2, cm.count >= 768 { palette = Array(bytes[cm.lowerBound..<(cm.lowerBound + 768)]) }
        try resources(&c)
        // layer and mask information
        do {
            let lmiLen = try c.len(large: isPSB)
            if lmiLen > c.remaining { warnings.append("The layer data is incomplete (the file ends early).") }
            var lmi = try c.sub(min(lmiLen, c.remaining))
            if lmiLen > 0 {
                do { try layerAndMaskInfo(&lmi) } catch {
                    warnings.append("Part of the layer data is damaged (\(error)).")
                }
            }
            imageDataStart = c.atEnd ? nil : c.pos
        } catch {
            warnings.append("The layer section could not be read (\(error)).")
        }
        layers = buildSummaries()
    }

    // MARK: Header and resources

    private func header(_ c: inout PSDCursor) throws {
        guard c.remaining >= 26 else { throw PSDImportError.unsupported("not a Photoshop file (too short)") }
        guard try c.fourCC() == "8BPS" else { throw PSDImportError.unsupported("not a Photoshop file") }
        let version = try c.u16()
        guard version == 1 || version == 2 else { throw PSDImportError.unsupported("unknown PSD version \(version)") }
        isPSB = version == 2
        try c.skip(6)
        channelCount = try c.u16()
        height = try c.u32(); width = try c.u32()
        depth = try c.u16(); colorMode = try c.u16()
        guard (1...56).contains(channelCount) else { throw PSDImportError.invalid("channel count \(channelCount)") }
        guard width > 0, height > 0 else { throw PSDImportError.invalid("empty canvas") }
        guard PSDLimits.plausible(width, height) else { throw PSDImportError.unsupported("canvas \(width) × \(height) px is too large") }
        guard [1, 8, 16, 32].contains(depth) else { throw PSDImportError.unsupported("\(depth)-bit channels") }
        guard [0, 1, 2, 3, 4, 7, 8, 9].contains(colorMode) else { throw PSDImportError.unsupported("colour mode \(colorMode)") }
    }

    private func resources(_ c: inout PSDCursor) throws {
        let n = try c.u32()
        guard n <= c.remaining else {
            warnings.append("The image resources are incomplete.")
            try c.skip(c.remaining)
            return
        }
        var r = try c.sub(n)
        var names1006: [String] = []
        while r.remaining >= 12 {
            guard let sig = try? r.fourCC(), ["8BIM", "MeSa", "AgHg", "PHUT", "DCSR"].contains(sig) else { break }
            guard let id = try? r.u16(), (try? r.pascal(pad: 2)) != nil, let size = try? r.u32(), size <= r.remaining,
                  var b = try? r.sub(size) else { break }
            if size % 2 == 1 { try? r.skip(1) }
            switch id {
            case 1005 where size >= 4:
                if let v = try? b.u32(), v > 0 { let ppi = Double(v) / 65536; if ppi.isFinite, ppi >= 1, ppi <= 100_000 { resolution = ppi } }
            case 1039: iccProfileSize = size
            case 1045:
                var names: [String] = []
                while b.remaining >= 4, let s = try? b.unicode() { names.append(s) }
                while names.last == "" { names.removeLast() }
                alphaNames = names
            case 1006:
                while b.remaining >= 1, let s = try? b.pascal(pad: 1) { names1006.append(s) }
                while names1006.last == "" { names1006.removeLast() }
            case 1047 where size >= 2: if let v = try? b.u16(), v < 256 { transparentIndex = v }
            default: break
            }
        }
        if alphaNames.isEmpty { alphaNames = names1006 }
    }

    // MARK: Layers

    private static let longKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD", "cinf"]

    private func layerAndMaskInfo(_ c: inout PSDCursor) throws {
        let liLen = try c.len(large: isPSB)
        if liLen > c.remaining { warnings.append("The layer records are incomplete.") }
        var li = try c.sub(min(liLen, c.remaining))
        if liLen > 0 { try layerInfo(&li) }
        guard c.remaining >= 4 else { return }
        let gm = try c.u32()
        try c.skip(min(gm, c.remaining))
        let globals = blocks(&c, global: true)
        // 16- and 32-bit documents keep their layers in a tagged block
        if records.isEmpty, let b = globals.first(where: { ["Lr16", "Lr32", "Layr"].contains($0.key) }), !b.range.isEmpty {
            var lc = PSDCursor(bytes, b.range)
            try layerInfo(&lc)
        }
    }

    private func layerInfo(_ c: inout PSDCursor) throws {
        let signed = try c.i16()
        mergedHasTransparency = signed < 0
        let count = abs(signed)
        var recs: [PSDRecord] = []
        for _ in 0..<count { recs.append(try record(&c)) }
        var ranges: [[(id: Int, range: Range<Int>)]] = []
        var short = false
        for r in recs {
            var list: [(id: Int, range: Range<Int>)] = []
            for ch in r.chans {
                if short || ch.len > c.remaining { short = true; continue }
                list.append((ch.id, try c.take(ch.len)))
            }
            ranges.append(list)
        }
        if short { warnings.append("Some layer pixels are missing (the file ends early).") }
        records = recs
        channelRanges = ranges
    }

    private func record(_ c: inout PSDCursor) throws -> PSDRecord {
        var r = PSDRecord()
        let top = try c.i32(), left = try c.i32(), bottom = try c.i32(), right = try c.i32()
        r.rect = IRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        let nc = try c.u16()
        guard nc <= c.remaining / (isPSB ? 10 : 6) else { throw PSDImportError.truncated }
        for _ in 0..<nc { r.chans.append((try c.i16(), try c.len(large: isPSB))) }
        guard try c.fourCC() == "8BIM" else { throw PSDImportError.invalid("layer record signature") }
        r.blendKey = try c.fourCC()
        r.opacity = try c.u8(); r.clipping = try c.u8(); r.flags = try c.u8()
        try c.skip(1)
        let extraLen = try c.u32()
        var e = try c.sub(extraLen)
        let mLen = try e.u32()
        var m = try e.sub(mLen)
        if mLen >= 18 { r.mask = try? maskInfo(&m, size: mLen) }
        let brLen = try e.u32()
        r.blendRanges = try e.take(brLen)
        r.name = try e.pascal(pad: 4)
        r.blocks = blocks(&e, global: false)
        for b in r.blocks {
            var bc = PSDCursor(bytes, b.range)
            switch b.key {
            case "luni": if let s = try? bc.unicode(), !s.isEmpty { r.name = s }
            case "lyid": if let v = try? bc.u32() { r.layerID = v }
            case "lsct", "lsdk":
                if let t = try? bc.u32(), (1...3).contains(t) {
                    r.section = t
                    if bc.remaining >= 8, (try? bc.fourCC()) == "8BIM", let k = try? bc.fourCC() { r.sectionBlend = k }
                }
            default: break
            }
        }
        return r
    }

    private func maskInfo(_ m: inout PSDCursor, size: Int) throws -> PSDMaskInfo {
        var i = PSDMaskInfo()
        func rect(_ c: inout PSDCursor) throws -> IRect {
            let t = try c.i32(), l = try c.i32(), b = try c.i32(), r = try c.i32()
            return IRect(x: l, y: t, width: max(0, r - l), height: max(0, b - t))
        }
        i.rect = try rect(&m)
        i.defaultColor = try m.u8()
        i.flags = try m.u8()
        if size == 20 { return i }
        if i.flags & 0x10 != 0 {
            let p = try m.u8()
            if p & 1 != 0 { i.userDensity = Double(try m.u8()) / 255 }
            if p & 2 != 0 { i.userFeather = try m.f64() }
            if p & 4 != 0 { i.vectorDensity = Double(try m.u8()) / 255 }
            if p & 8 != 0 { i.vectorFeather = try m.f64() }
        }
        if m.remaining >= 18 {
            i.realFlags = try m.u8()
            i.realDefault = try m.u8()
            i.realRect = try rect(&m)
        }
        return i
    }

    /// Tagged blocks up to the end of the cursor. Lengths are 8 bytes in PSB for a known set of keys; files in the
    /// wild disagree about padding, so after each block the next signature is looked for within 3 bytes.
    private func blocks(_ c: inout PSDCursor, global: Bool) -> [PSDBlock] {
        var out: [PSDBlock] = []
        let bytes = self.bytes
        let end = c.end
        func atSignature(_ p: Int) -> Bool {
            guard p >= 0, p + 4 <= end else { return false }
            let s = (bytes[p], bytes[p + 1], bytes[p + 2], bytes[p + 3])
            return s == (0x38, 0x42, 0x49, 0x4D) || s == (0x38, 0x42, 0x36, 0x34)   // 8BIM / 8B64
        }
        while c.remaining >= 12 {
            if !atSignature(c.pos) {
                guard let p = (1...3).map({ c.pos + $0 }).first(where: atSignature) else { break }
                try? c.seek(p)
            }
            guard let sig = try? c.fourCC(), let key = try? c.fourCC() else { break }
            let bodyStart = c.pos
            let wide = isPSB && (sig == "8B64" || PSDFile.longKeys.contains(key))
            var found: (Int, Int)? = nil
            for w in (isPSB ? (wide ? [8, 4] : [4, 8]) : [4]) {
                var t = c
                guard let l = try? (w == 8 ? t.u64() : t.u32()), l <= t.remaining else { continue }
                let after = t.pos + l
                let ok = after >= end - 3 || (0...3).contains { atSignature(after + $0) }
                if ok || !isPSB { found = (w, l); break }
            }
            guard let (w, l) = found else { break }
            try? c.seek(bodyStart + w)
            guard let r = try? c.take(l) else { break }
            out.append(PSDBlock(key: key, range: r))
            if global {
                let pad = (4 - l % 4) % 4
                if pad <= c.remaining, atSignature(c.pos + pad) || c.pos + pad >= end { try? c.skip(pad) }
            }
        }
        return out
    }

    // MARK: Layer summaries

    private static let fillKinds: [String: String] = ["SoCo": "Solid color", "GdFl": "Gradient", "PtFl": "Pattern"]

    /// Kind and detail of one record.
    package func kind(of r: PSDRecord) -> (PSDLayerKind, String) {
        if let s = r.section, s == 1 || s == 2 {
            return (r.has("artb") || r.has("artd") || r.has("abdd")) ? (.artboard, "") : (.group, s == 1 ? "open" : "closed")
        }
        if r.has("TySh") || r.has("tySh") { return (.text, "") }
        if r.has("SoLd") || r.has("SoLE") || r.has("PlLd") { return (.smartObject, r.has("SoLE") ? "linked" : "") }
        if let k = PSDAdjust.key(of: r) { return (.adjustment, PSDFile.adjustmentName(k)) }
        let fill = PSDFile.fillKinds.first { r.has($0.key) }
        if r.has("vscg") || (fill != nil && (r.has("vmsk") || r.has("vsms"))) {
            return (.shape, fill?.value ?? (r.has("vscg") ? "Vector" : ""))
        }
        if let fill { return (.fill, fill.value) }
        return (.pixel, "")
    }

    package static func adjustmentName(_ key: String) -> String {
        switch key {
        case "levl": return "Levels"
        case "curv": return "Curves"
        case "CgEd": return "Brightness/Contrast"
        case "brit": return "Brightness/Contrast"
        case "blnc": return "Color Balance"
        case "hue2", "hue ": return "Hue/Saturation"
        case "selc": return "Selective Color"
        case "mixr": return "Channel Mixer"
        case "grdm": return "Gradient Map"
        case "phfl": return "Photo Filter"
        case "expA": return "Exposure"
        case "vibA": return "Vibrance"
        case "blwh": return "Black & White"
        case "post": return "Posterize"
        case "thrs": return "Threshold"
        case "nvrt": return "Invert"
        case "clrL": return "Color Lookup"
        default: return key
        }
    }

    private func buildSummaries() -> [PSDLayerSummary] {
        var out: [PSDLayerSummary] = []
        var depth = 0
        for i in records.indices.reversed() {
            let r = records[i]
            if r.section == 3 { depth = max(0, depth - 1); continue }   // end of a group (its bottom)
            let (k, detail) = kind(of: r)
            let blendKey = (k == .group || k == .artboard) ? (r.sectionBlend ?? r.blendKey) : r.blendKey
            var fx: [String] = []
            var fxVisible = true
            if let b = r.block("lfx2") ?? r.block("lmfx"), let e = PSDLayerStyle.decode(PSDCursor(bytes).data(b)) {
                fx = e.activeNames
                fxVisible = e.enabled
            } else if r.has("lrFX") {
                fx = ["Effects (legacy format)"]
            }
            var fill: Double? = nil
            if let b = r.block("iOpa"), !b.isEmpty { fill = Double(bytes[b.lowerBound]) / 255 }
            let ids = Set(r.chans.map(\.id))
            let hasMask = ids.contains(-3) || (ids.contains(-2) && !(r.mask?.fromVector ?? false))
            out.append(PSDLayerSummary(
                name: r.name, depth: depth, kind: k, kindDetail: detail,
                isVisible: r.flags & 0x02 == 0,
                blendKey: blendKey, blendMode: BlendMode(psdKey: blendKey),
                opacity: Double(r.opacity) / 255, fillOpacity: fill,
                isClipped: r.clipping != 0, hasMask: hasMask, hasVectorMask: r.has("vmsk") || r.has("vsms"),
                effects: fx, effectsVisible: fxVisible, rect: r.rect, recordIndex: i))
            if k == .group || k == .artboard { depth += 1 }
        }
        return out
    }

    // MARK: Channel data

    private var bytesPerSample: Int { max(1, depth / 8) }
    private func rowBytes(_ w: Int) -> Int { depth == 1 ? (w + 7) / 8 : w * bytesPerSample }

    /// Raw big-endian samples of one channel. `rowCounts`: RLE row lengths stored ahead of all channels (image data
    /// section); nil when they precede this channel's data.
    private func samples(_ c: inout PSDCursor, compression: Int, width w: Int, height h: Int, rowCounts: [Int]?) throws -> [UInt8] {
        let rb = rowBytes(w)
        let total = rb * h
        let ratio = compression == 0 ? 1 : (compression == 1 ? 130 : 1100)
        guard total > 0, total / ratio <= c.remaining + (rowCounts?.reduce(0, +) ?? 0) + 64 else { throw PSDImportError.invalid("channel size") }
        var out = [UInt8](repeating: 0, count: total)
        switch compression {
        case 0:
            let r = try c.take(min(total, c.remaining))
            out.replaceSubrange(0..<r.count, with: bytes[r])
        case 1:
            var counts = rowCounts ?? []
            if rowCounts == nil {
                guard h <= c.remaining / (isPSB ? 4 : 2) else { throw PSDImportError.truncated }
                counts.reserveCapacity(h)
                for _ in 0..<h { counts.append(isPSB ? try c.u32() : try c.u16()) }
            }
            guard counts.count >= h else { throw PSDImportError.truncated }
            var p = c.pos
            let end = c.end
            bytes.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let n = min(counts[y], max(0, end - p))
                    PSDFile.unpackBits(src, p, n, dst, y * rb, rb)
                    p += n
                    if n < counts[y] { break }
                }
            } }
            try c.seek(min(p, end))
        case 2, 3:
            let r = try c.take(c.remaining)
            let res = bytes.withUnsafeBufferPointer { src in
                Inflate.zlibDecompressPartial(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(src)[r]), maxOutput: total, verifyChecksum: false, stopAtLimit: true)
            }
            guard !res.output.isEmpty else { throw PSDImportError.invalid("compressed channel") }
            for k in 0..<min(total, res.output.count) { out[k] = res.output[k] }
            if compression == 3 { unpredict(&out, width: w, height: h) }
        default:
            throw PSDImportError.unsupported("channel compression \(compression)")
        }
        return out
    }

    /// PackBits row decode, bounds-checked on both sides.
    private static func unpackBits(_ src: UnsafeBufferPointer<UInt8>, _ start: Int, _ n: Int, _ dst: UnsafeMutableBufferPointer<UInt8>, _ dstStart: Int, _ count: Int) {
        var s = start, o = 0
        let sEnd = min(src.count, start + n)
        let dEnd = min(count, dst.count - dstStart)
        while s < sEnd && o < dEnd {
            let c = Int(Int8(bitPattern: src[s])); s += 1
            if c >= 0 {
                let run = min(c + 1, sEnd - s, dEnd - o)
                if run <= 0 { break }
                for k in 0..<run { dst[dstStart + o + k] = src[s + k] }
                s += c + 1; o += run
            } else if c != -128 {
                guard s < sEnd else { break }
                let run = min(1 - c, dEnd - o)
                let v = src[s]
                for k in 0..<run { dst[dstStart + o + k] = v }
                s += 1; o += run
            }
        }
    }

    /// Undoes "ZIP with prediction": per-row deltas (8/16 bit) or byte-plane deltas (32 bit).
    private func unpredict(_ d: inout [UInt8], width w: Int, height h: Int) {
        let rb = rowBytes(w)
        guard d.count >= rb * h, w > 0 else { return }
        switch depth {
        case 16:
            for y in 0..<h {
                let o = y * rb
                var prev = Int(d[o]) << 8 | Int(d[o + 1])
                for x in 1..<w {
                    let v = ((Int(d[o + x * 2]) << 8 | Int(d[o + x * 2 + 1])) &+ prev) & 0xffff
                    d[o + x * 2] = UInt8(v >> 8); d[o + x * 2 + 1] = UInt8(v & 0xff)
                    prev = v
                }
            }
        case 32:
            var tmp = [UInt8](repeating: 0, count: rb)
            for y in 0..<h {
                let o = y * rb
                for i in 1..<rb { d[o + i] = d[o + i] &+ d[o + i - 1] }
                for x in 0..<w { for k in 0..<4 { tmp[x * 4 + k] = d[o + k * w + x] } }
                for i in 0..<rb { d[o + i] = tmp[i] }
            }
        default:
            for y in 0..<h {
                let o = y * rb
                if rb > 1 { for x in 1..<rb { d[o + x] = d[o + x] &+ d[o + x - 1] } }
            }
        }
    }

    private static let linearToSRGB: [UInt8] = (0...4096).map { i in
        let x = Double(i) / 4096
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (v * 255).rounded())))
    }

    /// Raw samples → one byte per pixel. 32-bit colour is linear light (encoded as sRGB); masks and alpha stay linear.
    private func reduce(_ raw: [UInt8], width w: Int, height h: Int, color: Bool) -> [UInt8] {
        let count = w * h
        switch depth {
        case 1:
            var p = [UInt8](repeating: 255, count: count)
            let rb = rowBytes(w)
            for y in 0..<h { for x in 0..<w where y * rb + x / 8 < raw.count && raw[y * rb + x / 8] & (0x80 >> UInt8(x % 8)) != 0 { p[y * w + x] = 0 } }
            return p
        case 16:
            var out = [UInt8](repeating: 0, count: count)
            let n = min(count, raw.count / 2)
            for i in 0..<n { out[i] = UInt8(((Int(raw[i * 2]) << 8 | Int(raw[i * 2 + 1])) + 128) / 257) }
            return out
        case 32:
            var out = [UInt8](repeating: 0, count: count)
            let n = min(count, raw.count / 4)
            let lut = PSDFile.linearToSRGB
            for i in 0..<n {
                let bits = UInt32(raw[i * 4]) << 24 | UInt32(raw[i * 4 + 1]) << 16 | UInt32(raw[i * 4 + 2]) << 8 | UInt32(raw[i * 4 + 3])
                let f = Float(bitPattern: bits)
                let v = f.isNaN ? 0 : min(1, max(0, f))
                out[i] = color ? lut[Int((v * 4096).rounded())] : UInt8((v * 255).rounded())
            }
            return out
        default:
            if raw.count == count { return raw }
            return Array(raw.prefix(count)) + [UInt8](repeating: 0, count: max(0, count - raw.count))
        }
    }

    // MARK: Colour

    /// Number of colour channels of the colour mode.
    package var colorChannels: Int {
        switch colorMode {
        case 3, 9: return 3
        case 4: return 4
        default: return 1
        }
    }

    /// Colour planes → straight RGB planes (missing planes are black; CMYK and Lab use simple formulas, no profile).
    private func rgb(_ planes: [[UInt8]?], count n: Int) -> ([UInt8], [UInt8], [UInt8]) {
        let zero = [UInt8](repeating: 0, count: n)
        func p(_ i: Int) -> [UInt8]? { i < planes.count ? planes[i].flatMap { $0.count >= n ? $0 : nil } : nil }
        switch colorMode {
        case 3:
            return (p(0) ?? zero, p(1) ?? zero, p(2) ?? zero)
        case 4:
            // stored inverted (255 = no ink)
            let c = p(0) ?? zero, m = p(1) ?? zero, y = p(2) ?? zero
            let k = p(3) ?? [UInt8](repeating: 255, count: n)
            var r = zero, g = zero, b = zero
            for i in 0..<n {
                let kk = Int(k[i])
                r[i] = UInt8(Int(c[i]) * kk / 255); g[i] = UInt8(Int(m[i]) * kk / 255); b[i] = UInt8(Int(y[i]) * kk / 255)
            }
            return (r, g, b)
        case 9:
            let L = p(0) ?? zero, A = p(1) ?? [UInt8](repeating: 128, count: n), B = p(2) ?? [UInt8](repeating: 128, count: n)
            var r = zero, g = zero, b = zero
            for i in 0..<n {
                let (rr, gg, bb) = PSDFile.labToSRGB(Double(L[i]) * 100 / 255, Double(A[i]) - 128, Double(B[i]) - 128)
                r[i] = rr; g[i] = gg; b[i] = bb
            }
            return (r, g, b)
        case 2:
            let idx = p(0) ?? zero
            guard palette.count >= 768 else { return (idx, idx, idx) }
            var r = zero, g = zero, b = zero
            for i in 0..<n { let v = Int(idx[i]); r[i] = palette[v]; g[i] = palette[256 + v]; b[i] = palette[512 + v] }
            return (r, g, b)
        default:
            let v = p(0) ?? zero
            return (v, v, v)
        }
    }

    /// CIE L*a*b* (D50) → 8-bit sRGB (Bradford-adapted to D65).
    package static func labToSRGB(_ L: Double, _ a: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func finv(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : 3 * (6.0 / 29) * (6.0 / 29) * (t - 4.0 / 29) }
        let X = 0.9642 * finv(fx), Y = finv(fy), Z = 0.8249 * finv(fz)
        // XYZ (D50) → linear sRGB, Bradford-adapted matrix
        let rl = 3.1338561 * X - 1.6168667 * Y - 0.4906146 * Z
        let gl = -0.9787684 * X + 1.9161415 * Y + 0.0334540 * Z
        let bl = 0.0719453 * X - 0.2289914 * Y + 1.4052427 * Z
        func enc(_ v: Double) -> UInt8 {
            let c = max(0, min(1, v))
            let s = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return UInt8((s * 255).rounded())
        }
        return (enc(rl), enc(gl), enc(bl))
    }

    private static func interleave(_ r: [UInt8], _ g: [UInt8], _ b: [UInt8], _ a: [UInt8]?, count n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            out[i * 4] = r[i]; out[i * 4 + 1] = g[i]; out[i * 4 + 2] = b[i]
            if let a { out[i * 4 + 3] = a[i] }
        }
        return out
    }

    // MARK: Composite (image data section)

    /// Whether the image data section has the composite's transparency as its first extra channel (same rule as
    /// the Mac importer: Photoshop lists that channel in the alpha names in some files and not in others).
    package var compositeHasTransparency: Bool {
        let count = max(0, channelCount - colorChannels)
        guard count > 0 else { return false }
        let coversAll = alphaNames.count == count
        return mergedHasTransparency || count > alphaNames.count || (coversAll && alphaNames.first?.lowercased() == "transparency")
    }

    /// True when the file has an image data section (Photoshop always writes one; "Maximize compatibility" off
    /// leaves it blank white, which still decodes).
    package var hasComposite: Bool { imageDataStart != nil }

    /// The flattened picture stored in the file, as straight RGBA. nil when the file has no image data section.
    package func composite() throws -> RGBA8Image? {
        guard let start = imageDataStart else { return nil }
        var c = PSDCursor(bytes, start..<bytes.count)
        let W = width, H = height
        guard W * H <= 400_000_000 else { throw PSDImportError.unsupported("canvas too large to preview") }
        let comp = try c.u16()
        let n = colorChannels
        guard channelCount >= n else { throw PSDImportError.invalid("channel count") }
        let wantAlpha = compositeHasTransparency
        let take = n + (wantAlpha ? 1 : 0)
        var counts: [[Int]]? = nil
        if comp == 1 {
            guard channelCount * H <= c.remaining / (isPSB ? 4 : 2) else { throw PSDImportError.truncated }
            var all: [[Int]] = []
            for _ in 0..<channelCount {
                var row: [Int] = []
                row.reserveCapacity(H)
                for _ in 0..<H { row.append(isPSB ? try c.u32() : try c.u16()) }
                all.append(row)
            }
            counts = all
        } else if comp == 2 || comp == 3 {
            // rare: the whole section as one zlib stream (Photoshop never writes this, some tools do)
            let raw = try samples(&c, compression: comp, width: W, height: H * channelCount, rowCounts: nil)
            var planes: [[UInt8]?] = []
            let rb = rowBytes(W) * H
            for ch in 0..<take where (ch + 1) * rb <= raw.count {
                planes.append(reduce(Array(raw[(ch * rb)..<((ch + 1) * rb)]), width: W, height: H, color: ch < n))
            }
            return finishComposite(planes, wantAlpha: wantAlpha)
        } else if comp != 0 {
            throw PSDImportError.unsupported("image data compression \(comp)")
        }
        var planes: [[UInt8]?] = []
        for ch in 0..<take {
            guard let raw = try? samples(&c, compression: comp, width: W, height: H, rowCounts: counts?[ch]) else {
                if ch == 0 { throw PSDImportError.truncated }
                warnings.append("The composite is incomplete.")
                break
            }
            planes.append(reduce(raw, width: W, height: H, color: ch < n))
        }
        return finishComposite(planes, wantAlpha: wantAlpha)
    }

    private func finishComposite(_ planesIn: [[UInt8]?], wantAlpha: Bool) -> RGBA8Image? {
        var planes = planesIn
        let n = colorChannels, W = width, H = height, count = W * H
        guard let first = planes.first, first != nil else { return nil }
        while planes.count < n + (wantAlpha ? 1 : 0) { planes.append(nil) }
        var (r, g, b) = rgb(Array(planes.prefix(n)), count: count)
        var alpha: [UInt8]? = wantAlpha ? planes[n].flatMap { $0.count >= count ? $0 : nil } : nil
        if colorMode == 2, let ti = transparentIndex, let idx = planes[0] { alpha = idx.map { Int($0) == ti ? 0 : 255 } }
        if let a = alpha, colorMode == 3 || colorMode == 1 || colorMode == 8 {
            // the composite is stored matted on white: remove the matte
            func unmatte(_ p: inout [UInt8]) {
                for i in 0..<count where a[i] != 0 && a[i] != 255 {
                    let v = (Int(p[i]) - 255) * 255 / Int(a[i]) + 255
                    p[i] = UInt8(max(0, min(255, v)))
                }
            }
            unmatte(&r); unmatte(&g); unmatte(&b)
        }
        return RGBA8Image(width: W, height: H, pixels: PSDFile.interleave(r, g, b, alpha, count: count))
    }

    // MARK: Layer pixels

    /// The pixels stored for record `index` (Photoshop's rendering of the layer, without its mask) at `rect`'s size.
    /// nil for groups, empty layers and layers whose pixels are missing.
    package func layerImage(_ index: Int) -> RGBA8Image? {
        guard records.indices.contains(index), index < channelRanges.count else { return nil }
        let r = records[index]
        let w = r.rect.width, h = r.rect.height
        guard w > 0, h > 0, PSDLimits.plausible(w, h), w * h <= 200_000_000 else { return nil }
        let n = colorChannels
        var planes = [Int: [UInt8]]()
        for ch in channelRanges[index] where ch.id >= -1 && ch.id < n {
            var c = PSDCursor(bytes, ch.range)
            guard c.remaining >= 2, let comp = try? c.u16(),
                  let raw = try? samples(&c, compression: comp, width: w, height: h, rowCounts: nil) else { continue }
            planes[ch.id] = reduce(raw, width: w, height: h, color: ch.id >= 0)
        }
        guard planes.keys.contains(where: { $0 >= 0 }) else { return nil }
        let (R, G, B) = rgb((0..<n).map { planes[$0] }, count: w * h)
        let A = planes[-1].flatMap { $0.count >= w * h ? $0 : nil }
        return RGBA8Image(width: w, height: h, pixels: PSDFile.interleave(R, G, B, A, count: w * h))
    }

    /// Thumbnail of record `index` as Photoshop's Layers panel shows it: the layer in place on the canvas, scaled
    /// to fit `maxSide` (canvas aspect ratio). nil when the layer has no pixels.
    package func layerThumbnail(_ index: Int, maxSide: Int) -> RGBA8Image? {
        guard let img = layerImage(index), maxSide > 0 else { return nil }
        let s = Double(maxSide) / Double(max(width, height))
        let tw = max(1, Int((Double(width) * s).rounded())), th = max(1, Int((Double(height) * s).rounded()))
        return img.resampled(width: tw, height: th, placing: records[index].rect, canvasWidth: width, canvasHeight: height)
    }

    // MARK: Text summary

    /// Multi-line description: header facts, then the layer tree.
    package func describe(fileName: String? = nil) -> String {
        var s = ""
        if let fileName { s += "File:        \(fileName)\n" }
        s += "Format:      \(isPSB ? "PSB (large document)" : "PSD")\n"
        s += "Size:        \(width) × \(height) px\n"
        s += "Bit depth:   \(depth) bits/channel\n"
        s += "Colour mode: \(PSDColorMode.name(colorMode))\(iccProfileSize > 0 ? " (embedded profile)" : "")\n"
        s += "Channels:    \(channelCount)\n"
        s += "Resolution:  \(resolution.map { String(format: "%.0f ppi", $0) } ?? "not stored")\n"
        s += "Layers:      \(layers.count)\n"
        s += "Composite:   \(hasComposite ? "stored\(compositeHasTransparency ? " (with transparency)" : "")" : "none")\n"
        for w in warnings { s += "Warning:     \(w)\n" }
        if !layers.isEmpty { s += "\nLayer tree (top of the stack first):\n" }
        for l in layers { s += PSDFile.describe(l) + "\n" }
        return s
    }

    package static func describe(_ l: PSDLayerSummary) -> String {
        var parts: [String] = []
        let kind = l.kindDetail.isEmpty || l.kind == .group ? l.kind.displayName : "\(l.kind.displayName): \(l.kindDetail)"
        parts.append(kind)
        parts.append(l.blendMode.displayName)
        parts.append("\(Int((l.opacity * 100).rounded()))%")
        if let f = l.fillOpacity, f < 1 { parts.append("fill \(Int((f * 100).rounded()))%") }
        if l.isClipped { parts.append("clipped") }
        if l.hasMask { parts.append("mask") }
        if l.hasVectorMask && l.kind != .shape { parts.append("vector mask") }
        if l.kind != .group && l.kind != .artboard && l.rect.width > 0 { parts.append("\(l.rect.width)×\(l.rect.height) at \(l.rect.x),\(l.rect.y)") }
        var line = String(repeating: "  ", count: l.depth) + (l.isVisible ? "[o] " : "[-] ") + (l.name.isEmpty ? "(unnamed)" : l.name)
        line += "  (" + parts.joined(separator: ", ") + ")"
        if !l.effects.isEmpty { line += "  fx: " + l.effects.joined(separator: ", ") + (l.effectsVisible ? "" : " (hidden)") }
        return line
    }
}
