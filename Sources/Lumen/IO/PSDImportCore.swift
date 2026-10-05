import Foundation
import CoreGraphics
import Accelerate
import Compression
import ColorSync
import ImageCratCore

final class PSDImporter: PSDByteSource {
    struct Result {
        var state: DocumentState
        var report: PSDImportReport
        /// Patterns stored in the file that fill layers / shapes / effects refer to.
        var patterns: [PatternDef] = []
        /// Photoshop's own rendering of each live layer (only collected when `keepStoredPixels` is on: tests).
        var stored: [UUID: RasterContent] = [:]
    }

    /// Test hook: also return the pixels Photoshop stored for layers that were imported live.
    static var keepStoredPixels = false
    var stored: [UUID: RasterContent] = [:]

    static let maxNesting = 4

    static func read(url: URL) throws -> Result {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data: data, name: url.lastPathComponent, baseURL: url.deletingLastPathComponent())
    }

    /// Every pattern stored in the file, used or not (tests; pattern libraries).
    static func patterns(data: Data) -> [PatternDef] {
        let imp = PSDImporter(bytes: [UInt8](data), name: "", nesting: 0, baseURL: nil)
        do {
            var c = PSDCursor(imp.bytes)
            try imp.header(&c)
            try imp.colorModeData(&c)
            var st = DocumentState(width: imp.W, height: imp.H)
            try imp.resources(&c, &st)
            let lmi = try c.len(large: imp.large)
            var l = try c.sub(min(lmi, c.remaining))
            try? imp.layerAndMaskInfo(&l)
            imp.parseGlobals()
        } catch { return [] }
        return imp.patterns.values.sorted { $0.id < $1.id }
    }

    /// Test hook: makes every read fail, to exercise the "open the flattened picture instead" path.
    static var failForTesting = false

    static func read(data: Data, name: String, nesting: Int = 0, baseURL: URL? = nil) throws -> Result {
        if failForTesting { throw PSDImportError.invalid("forced failure (test)") }
        let imp = PSDImporter(bytes: [UInt8](data), name: name, nesting: nesting, baseURL: baseURL)
        return try imp.run()
    }

    /// The flattened composite stored in the file (image data section) — the reference picture for tests.
    /// `matte`: the colour channels exactly as stored (Photoshop mattes them on white) with the transparency ignored.
    static func mergedImage(data: Data, matte: Bool = false) -> PixelBuffer? {
        let imp = PSDImporter(bytes: [UInt8](data), name: "", nesting: 0, baseURL: nil)
        do {
            var c = PSDCursor(imp.bytes)
            try imp.header(&c)
            try imp.colorModeData(&c)
            var st = DocumentState(width: imp.W, height: imp.H)
            try imp.resources(&c, &st)
            let lmi = try c.len(large: imp.large)
            try c.skip(min(lmi, c.remaining))
            return try imp.merged(&c, matte: matte)?.buffer
        } catch { return nil }
    }

    let bytes: [UInt8]
    let name: String
    let nesting: Int
    let baseURL: URL?
    var report = PSDImportReport()

    var large = false
    var channelCount = 3
    var W = 0, H = 0
    var depth = 8
    var mode = 3
    var palette: [UInt8] = []
    var transparentIndex: Int? = nil
    /// Global Light angle / altitude resources (1037 / 1049) found in the file.
    var storedLight = (angle: false, altitude: false)
    var icc: Data? = nil
    var alphaNames: [String] = []
    var mergedHasTransparency = false
    var linkGroups: [Int] = []
    var linkIDs: [Int: UUID] = [:]
    var records: [PSDRecord] = []
    var globals: [PSDBlock] = []
    var links: [String: PSDLinkedFile] = [:]
    var patterns: [String: PatternDef] = [:]
    var usedPatterns: [String] = []
    /// Exact Lumen layers stored by Lumen's exporter, by layer id (PSDExportLumen).
    var lumenEntries: [UInt32: PSDExportLumen.Entry] = [:]
    var truncated = false
    /// Guards state written while channels / embedded files are decoded on several threads.
    let lock = NSLock()
    /// Embedded Photoshop documents decoded ahead of the layer walk, by data offset (one per smart object using it).
    var prefetched: [Int: [Result]] = [:]
    lazy var converter = PSDColorConverter(mode: mode, icc: icc, palette: palette)

    init(bytes: [UInt8], name: String, nesting: Int, baseURL: URL?) {
        self.bytes = bytes; self.name = name; self.nesting = nesting; self.baseURL = baseURL
        report.fileName = name
    }

    // MARK: Driver

    func run() throws -> Result {
        var c = PSDCursor(bytes)
        try header(&c)
        try colorModeData(&c)
        var st = DocumentState(width: W, height: H)
        try resources(&c, &st)

        let lmiLen = try c.len(large: large)
        if lmiLen > c.remaining { truncated = true }
        var lmi = try c.sub(min(lmiLen, c.remaining))
        if lmiLen > 0 {
            do { try layerAndMaskInfo(&lmi) } catch {
                // records are only kept once all of them were walked; a failure before that leaves nothing to build from
                report.add(.flattened, layer: "", feature: "Layers", detail: records.isEmpty
                    ? "The layer data is damaged (\(error)); the flattened picture stored in the file is used instead."
                    : "Part of the layer data is damaged (\(error)); the layers that could be read are kept.")
            }
        }
        parseGlobals()

        st.layers = buildTree()
        inferGlobalLight(&st)
        var imageData = c
        if st.layers.isEmpty {
            if let m = try? merged(&c) {
                st.layers = [Layer.raster(name: "Background", buffer: m.buffer)]
                if !records.isEmpty { report.add(.flattened, layer: "", feature: "Layers", detail: "None of the layers could be built; the flattened picture stored in the file is used instead.") }
                if mode == 2 { st.imaging = indexedData() }
            } else if !truncated && lmiLen == 0 {
                throw PSDImportError.invalid("no readable image data")
            } else {
                throw PSDImportError.truncated
            }
        }
        if let chans = try? extraChannels(&imageData), !chans.isEmpty {
            st.alphaChannels = chans
            report.add(.editable, layer: "", feature: "Channels", detail: "\(chans.count) alpha channel\(chans.count == 1 ? "" : "s"): \(chans.map(\.name).joined(separator: ", "))")
        }
        if truncated { report.add(.info, layer: "", feature: "File", detail: "The file is incomplete: some layers may be missing or empty.") }
        finishDocument(&st)
        report.layerCount = st.allLayers.count
        return Result(state: st, report: report, patterns: usedPatterns.compactMap { patterns[$0] }, stored: stored)
    }

    // MARK: Header, colour mode data, resources

    func header(_ c: inout PSDCursor) throws {
        guard try c.fourCC() == "8BPS" else { throw PSDImportError.unsupported("not a Photoshop file") }
        let version = try c.u16()
        guard version == 1 || version == 2 else { throw PSDImportError.unsupported("unknown PSD version \(version)") }
        large = version == 2
        try c.skip(6)
        channelCount = try c.u16()
        H = try c.u32(); W = try c.u32()
        depth = try c.u16(); mode = try c.u16()
        guard (1...56).contains(channelCount) else { throw PSDImportError.invalid("channel count \(channelCount)") }
        guard W > 0, H > 0 else { throw PSDImportError.invalid("empty canvas") }
        guard PSDLimits.plausible(W, H) else { throw PSDImportError.unsupported("canvas \(W) × \(H) px is larger than ImageCrat supports") }
        guard [1, 8, 16, 32].contains(depth) else { throw PSDImportError.unsupported("\(depth)-bit channels") }
        guard [0, 1, 2, 3, 4, 8, 9].contains(mode) else { throw PSDImportError.unsupported("colour mode \(mode)") }
    }

    func colorModeData(_ c: inout PSDCursor) throws {
        let n = try c.u32()
        let r = try c.take(min(n, c.remaining))
        if n > r.count { throw PSDImportError.truncated }
        if mode == 2, r.count >= 768 { palette = Array(bytes[r.lowerBound..<(r.lowerBound + 768)]) }
    }

    /// A file without the Global Light resources (written by other tools): the light is the one its effects that use
    /// Global Light were drawn with ('lagl' / 'Lald'), so they keep their direction and new effects follow it.
    func inferGlobalLight(_ st: inout DocumentState) {
        guard !storedLight.angle || !storedLight.altitude else { return }
        for l in st.allLayers {
            let fx = l.effects
            let shadows = (fx.dropShadows + fx.innerShadows).filter { $0.isListed && $0.useGlobalLight }
            if !storedLight.angle, let s = shadows.first {
                st.globalLight.angle = s.angle; storedLight.angle = true
            }
            if fx.bevel.isListed && fx.bevel.useGlobalLight {
                if !storedLight.angle { st.globalLight.angle = fx.bevel.angle; storedLight.angle = true }
                if !storedLight.altitude { st.globalLight.altitude = fx.bevel.altitude; storedLight.altitude = true }
            }
            if storedLight.angle && storedLight.altitude { return }
        }
    }

    func resources(_ c: inout PSDCursor, _ st: inout DocumentState) throws {
        let n = try c.u32()
        guard n <= c.remaining else { throw PSDImportError.truncated }
        var r = try c.sub(n)
        var light = GlobalLight()
        var guides: [Guide] = []
        var paths: [NamedPath] = []
        while r.remaining >= 12 {
            guard let sig = try? r.fourCC(), sig == "8BIM" || sig == "MeSa" || sig == "AgHg" || sig == "PHUT" || sig == "DCSR" else { break }
            guard let id = try? r.u16(), let nm = try? r.pascal(pad: 2), let size = try? r.u32(), size <= r.remaining, var b = try? r.sub(size) else { break }
            if size % 2 == 1 { try? r.skip(1) }
            switch id {
            case 1005 where size >= 4:
                if let v = try? b.u32() { st.resolution = validResolution(Double(v) / 65536) }
            case 1037 where size >= 4: if let v = try? b.i32() { light.angle = Double(v); storedLight.angle = true }
            case 1049 where size >= 4: if let v = try? b.i32() { light.altitude = Double(v); storedLight.altitude = true }
            case 1032:
                // version, grid cycle (2 × 4), count, then (position in 1/32 px, direction) per guide
                guard (try? b.skip(12)) != nil, let count = try? b.u32(), count <= b.remaining / 5 else { break }
                for _ in 0..<count {
                    guard let pos = try? b.i32(), let dir = try? b.u8() else { break }
                    guides.append(Guide(isVertical: dir == 0, position: Double(pos) / 32))
                }
            case 1039: icc = b.data(b.pos..<b.end)
            case Int(PSDExportLumen.resourceID) where PSDExportLumen.resourceNames.contains(nm): lumenEntries = PSDExportLumen.decode(b.data(b.pos..<b.end))
            case 1045:
                var names: [String] = []
                while b.remaining >= 4, let s = try? b.unicode() { names.append(s) }
                while names.last == "" { names.removeLast() }   // padding reads as an empty name
                alphaNames = names
            case 1006 where alphaNames.isEmpty:
                var names: [String] = []
                while b.remaining >= 1, let s = try? b.pascal(pad: 1) { names.append(s) }
                while names.last == "" { names.removeLast() }
                alphaNames = names
            case 1047 where size >= 2: if let v = try? b.u16(), v < 256 { transparentIndex = v }
            case 1026:
                // one group number per layer record
                while b.remaining >= 2, let v = try? b.u16() { linkGroups.append(v) }
            case 1025, 2000...2997:
                let p = PSDVector.path(records: PSDCursor(bytes, b.pos..<b.end), width: W, height: H)
                if !p.path.isEmpty { paths.append(NamedPath(name: id == 1025 ? "Work Path" : (nm.isEmpty ? "Path \(paths.count + 1)" : nm), path: p.path)) }
            default: break
            }
        }
        st.globalLight = light
        st.guides = guides
        st.paths = paths
        if !guides.isEmpty { report.add(.editable, layer: "", feature: "Guides", detail: "\(guides.count) guide\(guides.count == 1 ? "" : "s")") }
        if !paths.isEmpty { report.add(.editable, layer: "", feature: "Paths", detail: "\(paths.count) saved path\(paths.count == 1 ? "" : "s")") }
    }

    /// Document-level settings derived from the header and resources.
    func finishDocument(_ st: inout DocumentState) {
        switch depth {
        case 16: st.bitDepth = .sixteen
        case 32: st.bitDepth = .thirtyTwo
        default: break
        }
        if depth > 8 { report.add(.info, layer: "", feature: "Bit depth", detail: "\(depth)-bit channels are stored as 8 bits per channel in ImageCrat.") }
        switch mode {
        case 0: st.colorMode = .bitmap
        case 1: st.colorMode = .grayscale
        case 2: st.colorMode = .indexed
        case 4: st.colorMode = .cmyk
        case 8:
            st.colorMode = .grayscale
            report.add(.flattened, layer: "", feature: "Colour mode", detail: "Duotone inks are not read: the document opens as Grayscale.")
        case 9: st.colorMode = .lab
        default: break
        }
        if mode == 4 || mode == 9 {
            report.add(.info, layer: "", feature: "Colour mode", detail: "\(mode == 4 ? "CMYK" : "Lab") pixels were converted to RGB; layers that blend with a mode other than Normal can look different.")
        }
        if mode == 3, let icc, let pn = PSDColorConverter.profileName(icc) {
            if let e = ColorProfiles.all.first(where: { $0.name.caseInsensitiveCompare(pn) == .orderedSame }) {
                st.profileName = ColorProfiles.isSRGB(e.name) ? (CGColorSpace.sRGB as String) : e.name
                if !ColorProfiles.isSRGB(e.name) { report.add(.editable, layer: "", feature: "Colour profile", detail: e.name) }
            } else if !pn.lowercased().contains("srgb") {
                report.add(.substituted, layer: "", feature: "Colour profile", detail: "“\(pn)” is not installed; the colour values are shown as sRGB.")
            }
        }
    }

    func indexedData() -> ImagingData {
        var d = ImagingData()
        if palette.count >= 768 {
            d.colorTable = (0..<256).map { RGBA(r8: palette[$0], g8: palette[256 + $0], b8: palette[512 + $0]) }
            d.transparentIndex = transparentIndex
        }
        return d
    }

    // MARK: Layer and mask information

    func layerAndMaskInfo(_ c: inout PSDCursor) throws {
        let liLen = try c.len(large: large)
        if liLen > c.remaining { truncated = true }
        var li = try c.sub(min(liLen, c.remaining))
        if liLen > 0 { try layerInfo(&li) }
        guard c.remaining >= 4 else { return }
        let gm = try c.u32()
        try c.skip(min(gm, c.remaining))
        globals = blocks(&c, global: true)
        // 16- and 32-bit documents keep their layers in a tagged block
        if records.isEmpty, let b = globals.first(where: { ["Lr16", "Lr32", "Layr"].contains($0.key) }), !b.range.isEmpty {
            var lc = PSDCursor(bytes, b.range)
            try layerInfo(&lc)
        }
    }

    func layerInfo(_ c: inout PSDCursor) throws {
        let signed = try c.i16()
        mergedHasTransparency = signed < 0
        let count = abs(signed)
        var recs: [PSDRecord] = []
        for _ in 0..<count { recs.append(try record(&c)) }
        records = recs
        for i in records.indices where i < linkGroups.count { records[i].linkGroup = linkGroups[i] }
        // channel image data, in record order: locate every channel, then decode them in parallel (a large file has
        // hundreds of megabytes of PackBits here)
        var jobs: [(rec: Int, id: Int, range: Range<Int>, rect: IRect)] = []
        walk: for i in records.indices {
            for ch in records[i].chans {
                guard ch.len <= c.remaining else { truncated = true; break walk }
                let r = try c.take(ch.len)
                let rect: IRect
                switch ch.id {
                case -2: rect = records[i].mask?.rect ?? .zero
                case -3: rect = records[i].mask?.realRect ?? .zero
                default: rect = records[i].rect
                }
                guard rect.width > 0, rect.height > 0, records[i].section == nil || ch.id < -1 else { continue }
                guard PSDLimits.plausible(rect.width, rect.height) else { continue }
                jobs.append((i, ch.id, r, rect))
            }
        }
        var planes = [[UInt8]?](repeating: nil, count: jobs.count)
        planes.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                let j = jobs[k]
                var cc = PSDCursor(bytes, j.range)
                (base + k).pointee = try? plane(&cc, width: j.rect.width, height: j.rect.height, color: j.id >= 0)
            }
        }
        for (k, j) in jobs.enumerated() { if let p = planes[k] { records[j.rec].planes[j.id] = p } }
    }

    func record(_ c: inout PSDCursor) throws -> PSDRecord {
        var r = PSDRecord()
        let top = try c.i32(), left = try c.i32(), bottom = try c.i32(), right = try c.i32()
        r.rect = IRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        let nc = try c.u16()
        guard nc <= c.remaining / (large ? 10 : 6) else { throw PSDImportError.truncated }
        for _ in 0..<nc { r.chans.append((try c.i16(), try c.len(large: large))) }
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
            case "luni": if let s = try? bc.unicode() { r.name = s }
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

    func maskInfo(_ m: inout PSDCursor, size: Int) throws -> PSDMaskInfo {
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
    func blocks(_ c: inout PSDCursor, global: Bool) -> [PSDBlock] {
        var out: [PSDBlock] = []
        func atSignature(_ p: Int) -> Bool {
            guard p + 4 <= c.end else { return false }
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
            let wide = large && (sig == "8B64" || PSDImporter.longKeys.contains(key))
            var found: (Int, Int)? = nil   // (length field size, length)
            for w in (large ? (wide ? [8, 4] : [4, 8]) : [4]) {
                var t = c
                guard let l = try? (w == 8 ? t.u64() : t.u32()), l <= t.remaining else { continue }
                let after = t.pos + l
                let ok = after >= c.end - 3 || (0...3).contains { atSignature(after + $0) }
                if ok || !large { found = (w, l); break }
            }
            guard let (w, l) = found else { break }
            try? c.seek(bodyStart + w)
            guard let r = try? c.take(l) else { break }
            out.append(PSDBlock(key: key, range: r))
            if global { let pad = (4 - l % 4) % 4; if pad <= c.remaining, atSignature(c.pos + pad) || c.pos + pad >= c.end { try? c.skip(pad) } }
        }
        return out
    }

    static let longKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD", "cinf"]

    func parseGlobals() {
        for b in globals {
            switch b.key {
            case "lnk2", "lnkD", "lnk3", "lnkE": PSDSmart.links(PSDCursor(bytes, b.range), into: &links)
            case "Patt", "Pat2", "Pat3": PSDVector.patterns(PSDCursor(bytes, b.range), into: &patterns)
            default: break
            }
        }
    }

    // MARK: Channel data

    /// One channel (compression word + data) reduced to 8 bits per sample.
    func plane(_ c: inout PSDCursor, width w: Int, height h: Int, color: Bool) throws -> [UInt8] {
        guard c.remaining >= 2 else { throw PSDImportError.truncated }
        let comp = try c.u16()
        let raw = try samples(&c, compression: comp, width: w, height: h, rowCounts: nil)
        return reduce(raw, count: w * h, color: color)
    }

    var bytesPerSample: Int { max(1, depth / 8) }
    func rowBytes(_ w: Int) -> Int { depth == 1 ? (w + 7) / 8 : w * bytesPerSample }

    /// Raw big-endian samples of one channel. `rowCounts`: RLE row lengths when they are stored ahead of all
    /// channels (image data section); nil when they precede this channel's data.
    func samples(_ c: inout PSDCursor, compression: Int, width w: Int, height h: Int, rowCounts: [Int]?) throws -> [UInt8] {
        let rb = rowBytes(w)
        let total = rb * h
        // refuse sizes the compressed data cannot possibly fill (PackBits ≤ 64:1, deflate ≤ ~1030:1)
        let ratio = compression == 0 ? 1 : (compression == 1 ? 130 : 1100)
        guard total > 0, total / ratio <= c.remaining + (rowCounts?.reduce(0, +) ?? 0) + 64 else { throw PSDImportError.invalid("channel size") }
        var out = [UInt8](repeating: 0, count: total)
        switch compression {
        case 0:
            let r = try c.take(min(total, c.remaining))
            bytes.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
                _ = memcpy(dst.baseAddress!, src.baseAddress! + r.lowerBound, r.count)
            } }
            if r.count < total { lock.lock(); truncated = true; lock.unlock() }
        case 1:
            var counts = rowCounts ?? []
            if rowCounts == nil {
                guard h <= c.remaining / (large ? 4 : 2) else { throw PSDImportError.truncated }
                counts.reserveCapacity(h)
                for _ in 0..<h { counts.append(large ? try c.u32() : try c.u16()) }
            }
            guard counts.count >= h else { throw PSDImportError.truncated }
            var p = c.pos
            let end = c.end
            bytes.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let n = min(counts[y], max(0, end - p))
                    PSDImporter.unpackBits(src.baseAddress! + p, n, dst.baseAddress! + y * rb, rb)
                    p += n
                    if n < counts[y] { break }
                }
            } }
            try c.seek(min(p, end))
        case 2, 3:
            let r = try c.take(c.remaining)
            guard let inflated = PSDImporter.inflate(bytes, r, expected: total) else { throw PSDImportError.invalid("compressed channel") }
            out = inflated
            if compression == 3 { unpredict(&out, width: w, height: h) }
        default:
            throw PSDImportError.unsupported("channel compression \(compression)")
        }
        return out
    }

    static func unpackBits(_ src: UnsafePointer<UInt8>, _ n: Int, _ dst: UnsafeMutablePointer<UInt8>, _ count: Int) {
        var s = 0, o = 0
        while s < n && o < count {
            let c = Int(Int8(bitPattern: src[s])); s += 1
            if c >= 0 {
                let run = min(c + 1, n - s, count - o)
                if run <= 0 { break }
                memcpy(dst + o, src + s, run)
                s += c + 1; o += run
            } else if c != -128 {
                guard s < n else { break }
                let run = min(1 - c, count - o)
                memset(dst + o, Int32(src[s]), run)
                s += 1; o += run
            }
        }
    }

    /// zlib stream → bytes. A stream that stops early leaves the rest zero (partial pixels rather than no layer).
    static func inflate(_ bytes: [UInt8], _ r: Range<Int>, expected: Int) -> [UInt8]? {
        guard r.count > 2, expected > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: expected)
        let n = bytes.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
            compression_decode_buffer(dst.baseAddress!, expected, src.baseAddress! + r.lowerBound + 2, r.count - 2, nil, COMPRESSION_ZLIB)
        } }
        return n > 0 ? out : nil
    }

    /// Undoes "ZIP with prediction": per-row deltas (8/16 bit) or byte-plane deltas (32 bit).
    func unpredict(_ d: inout [UInt8], width w: Int, height h: Int) {
        let rb = rowBytes(w)
        guard d.count >= rb * h, w > 0 else { return }
        d.withUnsafeMutableBufferPointer { p in
            switch depth {
            case 16:
                for y in 0..<h {
                    let row = p.baseAddress! + y * rb
                    var prev = Int(row[0]) << 8 | Int(row[1])
                    for x in 1..<w {
                        let v = (Int(row[x * 2]) << 8 | Int(row[x * 2 + 1])) &+ prev
                        row[x * 2] = UInt8((v >> 8) & 0xff); row[x * 2 + 1] = UInt8(v & 0xff)
                        prev = v & 0xffff
                    }
                }
            case 32:
                var tmp = [UInt8](repeating: 0, count: rb)
                for y in 0..<h {
                    let row = p.baseAddress! + y * rb
                    for i in 1..<rb { row[i] = row[i] &+ row[i - 1] }
                    // bytes are stored plane by plane (all first bytes, all second bytes, …)
                    for x in 0..<w { for k in 0..<4 { tmp[x * 4 + k] = row[k * w + x] } }
                    for i in 0..<rb { row[i] = tmp[i] }
                }
            default:
                for y in 0..<h {
                    let row = p.baseAddress! + y * rb
                    for x in 1..<rb { row[x] = row[x] &+ row[x - 1] }
                }
            }
        }
    }

    static let linearToSRGB: [UInt8] = (0...4096).map { i in
        let x = Double(i) / 4096
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (v * 255).rounded())))
    }

    /// Raw samples → one byte per pixel. 32-bit colour is linear light (encoded as sRGB); masks and alpha stay linear.
    func reduce(_ raw: [UInt8], count: Int, color: Bool) -> [UInt8] {
        switch depth {
        case 8: return raw.count == count ? raw : Array(raw.prefix(count)) + [UInt8](repeating: 0, count: max(0, count - raw.count))
        case 16:
            var out = [UInt8](repeating: 0, count: count)
            let n = min(count, raw.count / 2)
            raw.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { d in
                for i in 0..<n { d[i] = UInt8(((Int(s[i * 2]) << 8 | Int(s[i * 2 + 1])) + 128) / 257) }
            } }
            return out
        case 32:
            var out = [UInt8](repeating: 0, count: count)
            let n = min(count, raw.count / 4)
            let lut = PSDImporter.linearToSRGB
            raw.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { d in
                for i in 0..<n {
                    let bits = UInt32(s[i * 4]) << 24 | UInt32(s[i * 4 + 1]) << 16 | UInt32(s[i * 4 + 2]) << 8 | UInt32(s[i * 4 + 3])
                    let f = Float(bitPattern: bits)
                    let v = f.isNaN ? 0 : min(1, max(0, f))
                    d[i] = color ? lut[Int((v * 4096).rounded())] : UInt8((v * 255).rounded())
                }
            } }
            return out
        default: return raw
        }
    }

    // MARK: Pixels

    /// Premultiplied RGBA buffer from 8-bit planes (missing colour planes are black, missing alpha is opaque).
    static func rgba(width w: Int, height h: Int, r: [UInt8]?, g: [UInt8]?, b: [UInt8]?, a: [UInt8]?) -> PixelBuffer {
        let buf = PixelBuffer(width: w, height: h)
        let n = w * h
        let zero = [UInt8](repeating: 0, count: n)
        func ok(_ p: [UInt8]?) -> [UInt8]? { p.flatMap { $0.count >= n ? $0 : nil } }
        let R = ok(r) ?? zero, G = ok(g) ?? zero, B = ok(b) ?? zero
        let A = ok(a) ?? [UInt8](repeating: 255, count: n)
        R.withUnsafeBufferPointer { rp in G.withUnsafeBufferPointer { gp in B.withUnsafeBufferPointer { bp in A.withUnsafeBufferPointer { ap in
            func vb(_ p: UnsafeBufferPointer<UInt8>) -> vImage_Buffer {
                vImage_Buffer(data: UnsafeMutableRawPointer(mutating: p.baseAddress!), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            }
            var r0 = vb(rp), g0 = vb(gp), b0 = vb(bp), a0 = vb(ap)
            var dst = vImage_Buffer(data: buf.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: buf.bytesPerRow)
            vImageConvert_Planar8toARGB8888(&r0, &g0, &b0, &a0, &dst, vImage_Flags(kvImageNoFlags))   // argument order = byte order
            vImagePremultiplyData_RGBA8888(&dst, &dst, vImage_Flags(kvImageNoFlags))
        } } } }
        buf.markDirty()
        return buf
    }

    static func gray(width w: Int, height h: Int, _ p: [UInt8], invert: Bool = false) -> PixelBuffer {
        let buf = PixelBuffer(width: w, height: h, format: .gray)
        let q = buf.data.assumingMemoryBound(to: UInt8.self)
        let rows = min(h, p.count / max(1, w))
        p.withUnsafeBufferPointer { s in
            for y in 0..<rows {
                memcpy(q + y * buf.bytesPerRow, s.baseAddress! + y * w, w)
                if invert { for x in 0..<w { q[y * buf.bytesPerRow + x] = 255 - q[y * buf.bytesPerRow + x] } }
            }
        }
        buf.markDirty()
        return buf
    }

    /// The layer's stored pixels as RGBA (nil when the record has none).
    func pixels(_ r: PSDRecord) -> PixelBuffer? {
        let w = r.rect.width, h = r.rect.height
        guard PSDLimits.plausible(w, h), r.planes.keys.contains(where: { $0 >= 0 }) else { return nil }
        let n = converter.colorChannels
        let rgb = converter.rgb((0..<n).map { r.planes[$0] }, count: w * h, width: w, height: h)
        return PSDImporter.rgba(width: w, height: h, r: rgb.0, g: rgb.1, b: rgb.2, a: r.planes[-1])
    }

    // MARK: Saved alpha channels

    /// Image-data channels beyond the colour ones: whether the first is the composite's transparency, and the
    /// name of extra channel `k` (0 = first extra). Photoshop lists the transparency channel in the names
    /// ("Transparency") in some files and leaves it out in others.
    var extras: (count: Int, transparency: Bool, name: (Int) -> String?) {
        let count = max(0, channelCount - converter.colorChannels)
        let coversAll = alphaNames.count == count
        let transparency = count > 0 && (mergedHasTransparency || count > alphaNames.count || (coversAll && alphaNames.first?.lowercased() == "transparency"))
        let names = alphaNames
        return (count, transparency, { k in
            let i = coversAll ? k : k - (transparency ? 1 : 0)
            return i >= 0 && i < names.count && !names[i].isEmpty ? names[i] : nil
        })
    }

    /// Channels of the image data section beyond colour and transparency: the document's saved alpha (and spot)
    /// channels, named by resource 1045 / 1006. Only these planes are decoded.
    func extraChannels(_ c: inout PSDCursor) throws -> [AlphaChannel] {
        let n = converter.colorChannels
        let x = extras
        let first = n + (x.transparency ? 1 : 0)
        guard channelCount > first, depth != 1, PSDLimits.plausible(W, H), W * H <= 64_000_000 else { return [] }
        let comp = try c.u16()
        var out: [AlphaChannel] = []
        func add(_ raw: [UInt8], _ i: Int) {
            let plane = reduce(raw, count: W * H, color: false)
            out.append(AlphaChannel(name: x.name(i - n) ?? "Alpha \(i - first + 1)", buffer: PSDImporter.gray(width: W, height: H, plane)))
        }
        if comp == 0 {
            try c.skip(first * rowBytes(W) * H)
            for i in first..<min(channelCount, first + 24) { add(try samples(&c, compression: 0, width: W, height: H, rowCounts: nil), i) }
        } else if comp == 1 {
            guard channelCount * H <= c.remaining / (large ? 4 : 2) else { throw PSDImportError.truncated }
            var counts: [[Int]] = []
            for _ in 0..<channelCount {
                var row: [Int] = []
                row.reserveCapacity(H)
                for _ in 0..<H { row.append(large ? try c.u32() : try c.u16()) }
                counts.append(row)
            }
            try c.skip(counts.prefix(first).reduce(0) { $0 + $1.reduce(0, +) })
            for i in first..<min(channelCount, first + 24) { add(try samples(&c, compression: 1, width: W, height: H, rowCounts: counts[i]), i) }
        }
        return out
    }

    // MARK: Merged image

    /// Image data section: the flattened composite (plus alpha channels, which are ignored).
    func merged(_ c: inout PSDCursor, matte: Bool = false) throws -> (buffer: PixelBuffer, hasAlpha: Bool)? {
        guard PSDLimits.plausible(W, H) else { throw PSDImportError.unsupported("canvas too large") }
        let comp = try c.u16()
        let n = converter.colorChannels
        guard channelCount >= n else { throw PSDImportError.invalid("channel count") }
        // transparency is the first extra channel when it is not a saved alpha channel
        let wantAlpha = !matte && extras.transparency
        let take = n + (wantAlpha ? 1 : 0)
        var counts: [[Int]]? = nil
        if comp == 1 {
            guard channelCount * H <= c.remaining / (large ? 4 : 2) else { throw PSDImportError.truncated }
            var all: [[Int]] = []
            for _ in 0..<channelCount {
                var row: [Int] = []
                row.reserveCapacity(H)
                for _ in 0..<H { row.append(large ? try c.u32() : try c.u16()) }
                all.append(row)
            }
            counts = all
        } else if comp != 0 {
            throw PSDImportError.unsupported("image data compression \(comp)")
        }
        var planes: [[UInt8]?] = []
        for ch in 0..<take {
            guard let raw = try? samples(&c, compression: comp, width: W, height: H, rowCounts: counts?[ch]) else { planes.append(nil); break }
            if depth == 1 {
                // 1 bit per pixel, 1 = black
                var p = [UInt8](repeating: 255, count: W * H)
                let rb = rowBytes(W)
                for y in 0..<H { for x in 0..<W where raw[y * rb + x / 8] & (0x80 >> UInt8(x % 8)) != 0 { p[y * W + x] = 0 } }
                planes.append(p)
            } else {
                planes.append(reduce(raw, count: W * H, color: ch < n))
            }
        }
        guard let first = planes.first, first != nil else { return nil }
        while planes.count < take { planes.append(nil) }
        let rgb = converter.rgb(Array(planes.prefix(n)), count: W * H, width: W, height: H)
        var alpha: [UInt8]? = wantAlpha ? planes[n] : nil
        if mode == 2, let ti = transparentIndex, let idx = planes[0] { alpha = idx.map { Int($0) == ti ? 0 : 255 } }
        var (r, g, b) = rgb
        if let a = alpha, mode == 3 || mode == 1 {
            // the composite is stored matted on white: remove the matte so premultiplying gives the real colour
            func unmatte(_ p: [UInt8]?) -> [UInt8]? {
                guard var p, p.count == a.count else { return p }
                for i in 0..<p.count where a[i] != 0 && a[i] != 255 {
                    let v = (Int(p[i]) - 255) * 255 / Int(a[i]) + 255
                    p[i] = UInt8(max(0, min(255, v)))
                }
                return p
            }
            r = unmatte(r); g = unmatte(g); b = unmatte(b)
        }
        return (PSDImporter.rgba(width: W, height: H, r: r, g: g, b: b, a: alpha), alpha != nil)
    }
}

// MARK: - Colour conversion

/// Converts the channel planes of non-RGB documents to sRGB (through the embedded profile when there is one).
struct PSDColorConverter {
    let mode: Int
    let icc: Data?
    let palette: [UInt8]

    var colorChannels: Int {
        switch mode {
        case 3, 9: return 3
        case 4: return 4
        default: return 1
        }
    }

    static func profileName(_ icc: Data) -> String? {
        guard let p = ColorSyncProfileCreate(icc as CFData, nil)?.takeRetainedValue(),
              let s = ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() else { return nil }
        return s as String
    }

    func rgb(_ planes: [[UInt8]?], count: Int, width: Int, height: Int) -> ([UInt8]?, [UInt8]?, [UInt8]?) {
        func p(_ i: Int) -> [UInt8]? { i < planes.count ? planes[i].flatMap { $0.count >= count ? $0 : nil } : nil }
        switch mode {
        case 3: return (p(0), p(1), p(2))
        case 2:
            guard let idx = p(0), palette.count >= 768 else { return (p(0), p(0), p(0)) }
            var r = [UInt8](repeating: 0, count: count), g = r, b = r
            for i in 0..<count { let k = Int(idx[i]); r[i] = palette[k]; g[i] = palette[256 + k]; b[i] = palette[512 + k] }
            return (r, g, b)
        case 4:
            let zero = [UInt8](repeating: 255, count: count)   // stored inverted: 255 = no ink
            let c = p(0) ?? zero, m = p(1) ?? zero, y = p(2) ?? zero, k = p(3) ?? zero
            var inter = [UInt8](repeating: 0, count: count * 4)
            for i in 0..<count { inter[i * 4] = 255 - c[i]; inter[i * 4 + 1] = 255 - m[i]; inter[i * 4 + 2] = 255 - y[i]; inter[i * 4 + 3] = 255 - k[i] }
            let cs = icc.flatMap { CGColorSpace(iccData: $0 as CFData) }.flatMap { $0.model == .cmyk ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.genericCMYK)
            if let cs, let out = PSDColorConverter.convert(inter, components: 4, width: width, height: height, space: cs) { return out }
            var r = [UInt8](repeating: 0, count: count), g = r, b = r
            for i in 0..<count { r[i] = UInt8(Int(c[i]) * Int(k[i]) / 255); g[i] = UInt8(Int(m[i]) * Int(k[i]) / 255); b[i] = UInt8(Int(y[i]) * Int(k[i]) / 255) }
            return (r, g, b)
        case 9:
            let l = p(0) ?? [UInt8](repeating: 0, count: count), a = p(1) ?? [UInt8](repeating: 128, count: count), bb = p(2) ?? [UInt8](repeating: 128, count: count)
            var inter = [UInt8](repeating: 0, count: count * 3)
            for i in 0..<count { inter[i * 3] = l[i]; inter[i * 3 + 1] = a[i]; inter[i * 3 + 2] = bb[i] }
            let white: [CGFloat] = [0.9642, 1, 0.8249], black: [CGFloat] = [0, 0, 0], range: [CGFloat] = [-128, 127, -128, 127]
            if let cs = CGColorSpace(labWhitePoint: white, blackPoint: black, range: range),
               let out = PSDColorConverter.convert(inter, components: 3, width: width, height: height, space: cs) { return out }
            return (l, l, l)
        default:
            return (p(0), p(0), p(0))
        }
    }

    /// Black point compensation of a CMYK profile, the way Photoshop converts CMYK to RGB by default (relative
    /// colorimetric + BPC). Core Graphics converts without it: the darkest ink lands on ~(31,31,31) and SWOP red on
    /// (237,51,56) where Photoshop shows (5,6,6) and (237,28,36). In linear light the compensation is
    /// v' = (v − black) / (white − black), with the profile's black point found the usual way (perceptual black
    /// converted back relative-colorimetrically).
    struct BlackPoint: Equatable { var black: Double; var white: [Double] }

    static func blackPoint(_ cmyk: CGColorSpace) -> BlackPoint? {
        guard cmyk.model == .cmyk, let lab = CGColorSpace(name: CGColorSpace.genericLab), let lin = CGColorSpace(name: CGColorSpace.linearSRGB),
              let k = CGColor(colorSpace: lab, components: [0, 0, 0, 1])?.converted(to: cmyk, intent: .perceptual, options: nil),
              let kc = k.converted(to: lin, intent: .relativeColorimetric, options: nil)?.components, kc.count >= 3,
              let wc = CGColor(colorSpace: cmyk, components: [0, 0, 0, 0, 1])?.converted(to: lin, intent: .relativeColorimetric, options: nil)?.components, wc.count >= 3 else { return nil }
        let y = Double(0.2126 * kc[0] + 0.7152 * kc[1] + 0.0722 * kc[2])
        let w = wc.prefix(3).map { Double($0) }
        guard y.isFinite, y > 0.0005, y < 0.25, w.allSatisfy({ $0.isFinite && $0 > y + 0.5 }) else { return nil }
        return BlackPoint(black: y, white: w)
    }

    static let srgb16ToLinear: [Double] = (0..<65536).map { i in
        let v = Double(i) / 65535
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static let srgbToLinear: [Double] = (0..<256).map { i in
        let v = Double(i) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Per-channel tables applying `bp` to 8-bit sRGB values.
    static func compensationTables(_ bp: BlackPoint) -> [[UInt8]] {
        (0..<3).map { c in
            (0..<256).map { i in
                let v = clamp((srgbToLinear[i] - bp.black) / (bp.white[c] - bp.black), 0, 1)
                return PSDImporter.linearToSRGB[Int((v * 4096).rounded())]
            }
        }
    }

    /// Compensates 16-bit premultiplied sRGB samples (RGBA, little-endian words) into `out` (8-bit premultiplied).
    static func compensate(_ src: UnsafePointer<UInt16>, srcRowWords: Int, into out: PixelBuffer, _ bp: BlackPoint) {
        let dst = out.data.assumingMemoryBound(to: UInt8.self)
        let lut = PSDImporter.linearToSRGB, dec = srgb16ToLinear
        for y in 0..<out.height {
            let row = src + y * srcRowWords, o = dst + y * out.bytesPerRow
            for x in 0..<out.width {
                let a = Double(row[x * 4 + 3]) / 65535
                guard a > 0 else { o[x * 4] = 0; o[x * 4 + 1] = 0; o[x * 4 + 2] = 0; o[x * 4 + 3] = 0; continue }
                for c in 0..<3 {
                    let e = min(65535, Int((Double(row[x * 4 + c]) / a).rounded()))
                    let v = clamp((dec[e] - bp.black) / (bp.white[c] - bp.black), 0, 1)
                    o[x * 4 + c] = UInt8((Double(lut[Int((v * 4096).rounded())]) * a).rounded())
                }
                o[x * 4 + 3] = UInt8((a * 255).rounded())
            }
        }
        out.markDirty()
    }

    /// Draws interleaved samples of `space` into an sRGB bitmap and returns its planes.
    static func convert(_ inter: [UInt8], components: Int, width w: Int, height h: Int, space: CGColorSpace) -> ([UInt8]?, [UInt8]?, [UInt8]?)? {
        // large images convert in strips on several threads
        let strip = 256
        if h > strip * 2, w * h > 1_000_000, inter.count >= w * h * components {
            let n = (h + strip - 1) / strip
            var parts = [([UInt8]?, [UInt8]?, [UInt8]?)?](repeating: nil, count: n)
            parts.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: n) { k in
                    let y0 = k * strip, rows = min(strip, h - y0)
                    let sub = Array(inter[(y0 * w * components)..<((y0 + rows) * w * components)])
                    (base + k).pointee = convert(sub, components: components, width: w, height: rows, space: space)
                }
            }
            var r = [UInt8](), g = [UInt8](), b = [UInt8]()
            r.reserveCapacity(w * h); g.reserveCapacity(w * h); b.reserveCapacity(w * h)
            for p in parts {
                guard let p, let pr = p.0, let pg = p.1, let pb = p.2 else { return nil }
                r += pr; g += pg; b += pb
            }
            return (r, g, b)
        }
        guard w > 0, h > 0, inter.count >= w * h * components, let prov = CGDataProvider(data: Data(inter) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: w * components, space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let out = ctx.data else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let q = out.assumingMemoryBound(to: UInt8.self)
        let n = w * h
        var r = [UInt8](repeating: 0, count: n), g = r, b = r
        if let bp = blackPoint(space) {
            let t = compensationTables(bp)
            for i in 0..<n { r[i] = t[0][Int(q[i * 4])]; g[i] = t[1][Int(q[i * 4 + 1])]; b[i] = t[2][Int(q[i * 4 + 2])] }
        } else {
            for i in 0..<n { r[i] = q[i * 4]; g[i] = q[i * 4 + 1]; b[i] = q[i * 4 + 2] }
        }
        return (r, g, b)
    }
}
