import Foundation
import ImageCratCore

// Strict structural check of a PSD / PSB written by PSDExport (tests): every section length adds up, every tagged
// block parses to its exact length (descriptors with the importer's descriptor parser, engine data with its engine
// data parser), PSB uses 8-byte lengths where required, channel data decodes to the declared size and group markers
// balance. Independent of PSDImporter's tolerant reader.

enum PSDExportValidator {
    struct Report {
        var problems: [String] = []
        var layerCount = 0
        var blockKeys: [String: Int] = [:]
        var globalKeys: [String] = []
        var resourceIDs: [Int] = []
    }

    static func validate(_ data: Data) -> Report {
        var rep = Report()
        let b = [UInt8](data)
        var c = PSDCursor(b)
        func fail(_ s: String) { rep.problems.append(s) }
        do {
            guard try c.fourCC() == "8BPS" else { fail("signature"); return rep }
            let version = try c.u16()
            guard version == 1 || version == 2 else { fail("version \(version)"); return rep }
            let large = version == 2
            for _ in 0..<6 where try c.u8() != 0 { fail("reserved bytes") }
            let channels = try c.u16(), H = try c.u32(), W = try c.u32(), depth = try c.u16(), mode = try c.u16()
            if !(1...56).contains(channels) { fail("channel count \(channels)") }
            if depth != 8 && depth != 16 { fail("depth \(depth)") }
            if mode != 3 { fail("mode \(mode)") }
            if !large && (W > 30000 || H > 30000) { fail("PSD larger than 30000 px") }
            let cm = try c.u32()
            if cm != 0 { fail("colour mode data \(cm)") }
            // resources
            let resLen = try c.u32()
            var r = try c.sub(resLen)
            while !r.atEnd {
                guard try r.fourCC() == "8BIM" else { fail("resource signature"); break }
                let id = try r.u16()
                _ = try r.pascal(pad: 2)
                let n = try r.u32()
                try r.skip(n)
                if n % 2 == 1 { guard try r.u8() == 0 else { fail("resource \(id) padding"); break } }
                rep.resourceIDs.append(id)
            }
            // layer and mask information
            let lmiLen = try c.len(large: large)
            var lmi = try c.sub(lmiLen)
            let liLen = try lmi.len(large: large)
            var li = try lmi.sub(liLen)
            if liLen > 0 {
                if depth == 16 { fail("16-bit layers outside 'Lr16'") }
                layerInfo(&li, b, large: large, depth: depth, &rep)
            }
            let gm = try lmi.u32()
            try lmi.skip(gm)
            while lmi.remaining >= 12 {
                guard try lmi.fourCC() == "8BIM" else { fail("global block signature"); break }
                let key = try lmi.fourCC()
                let n = (large && PSDExport.longKeys.contains(key)) ? try lmi.u64() : try lmi.u32()
                var body = try lmi.sub(n)
                rep.globalKeys.append(key)
                switch key {
                case "Lr16": if depth != 16 { fail("'Lr16' in an 8-bit file") }; layerInfo(&body, b, large: large, depth: depth, &rep)
                case "lnk2", "lnkE":
                    var links: [String: PSDLinkedFile] = [:]
                    PSDSmart.links(body, into: &links)
                    if links.isEmpty { fail("'\(key)' has no readable entries") }
                    // embedded files in 'lnk2', references to files on disk in 'lnkE'
                    if links.values.contains(where: { ($0.externalPath != nil) != (key == "lnkE") }) { fail("'\(key)' holds a record of the other kind") }
                case "Mt16": if depth != 16 || n != 0 { fail("'Mt16' (\(n) bytes) at \(depth) bits") }
                case "Txt2":
                    // a sequence of /key value pairs (no enclosing << >>)
                    if (try? PSDEngineParser.parse([0x3C, 0x3C] + Array(b[body.pos..<body.end]) + [0x3E, 0x3E])) == nil { fail("'Txt2' does not parse as engine data") }
                case "Patt":
                    var pats: [String: PatternDef] = [:]
                    PSDVector.patterns(body, into: &pats)
                    if pats.isEmpty { fail("'Patt' has no readable patterns") }
                default: fail("unexpected global block '\(key)'")
                }
                let pad = (4 - n % 4) % 4
                for _ in 0..<pad where try lmi.u8() != 0 { fail("global padding") }
            }
            if !lmi.atEnd { fail("\(lmi.remaining) stray bytes after the global blocks") }
            // merged image
            let comp = try c.u16()
            let rb = W * depth / 8
            // 16-bit composites are raw (the system decoder cannot read them as RLE), 8-bit ones RLE
            if comp != (depth == 16 ? 0 : 1) { fail("merged compression \(comp) at \(depth) bits") }
            if comp == 0 {
                _ = try c.take(rb * channels * H)
                if !c.atEnd { fail("\(c.remaining) bytes after the image data") }
                return rep
            }
            var counts: [Int] = []
            for _ in 0..<(channels * H) { counts.append(large ? try c.u32() : try c.u16()) }
            var row = [UInt8](repeating: 0, count: rb)
            for n in counts {
                let rng = try c.take(n)
                if !unpackExactly(b, rng, &row) { fail("merged row does not decode to \(rb) bytes"); break }
            }
            if !c.atEnd { fail("\(c.remaining) bytes after the image data") }
        } catch {
            fail("truncated: \(error)")
        }
        return rep
    }

    /// PackBits stream that fills `out` exactly and uses every input byte.
    static func unpackExactly(_ b: [UInt8], _ r: Range<Int>, _ out: inout [UInt8]) -> Bool {
        var s = r.lowerBound, o = 0
        while s < r.upperBound {
            let n = Int(Int8(bitPattern: b[s])); s += 1
            if n >= 0 {
                guard s + n + 1 <= r.upperBound, o + n + 1 <= out.count else { return false }
                o += n + 1; s += n + 1
            } else if n != -128 {
                guard s < r.upperBound, o + 1 - n <= out.count else { return false }
                o += 1 - n; s += 1
            }
        }
        return o == out.count
    }

    static func layerInfo(_ c: inout PSDCursor, _ b: [UInt8], large: Bool, depth: Int, _ rep: inout Report) {
        func fail(_ s: String) { rep.problems.append(s) }
        do {
            let count = abs(try c.i16())
            var recs: [(IRect, [(Int, Int)], [String: Range<Int>], IRect?, IRect?, String)] = []
            var open = 0
            for i in 0..<count {
                let t = try c.i32(), l = try c.i32(), bt = try c.i32(), rt = try c.i32()
                guard bt >= t, rt >= l else { fail("layer \(i): inverted rectangle"); return }
                let rect = IRect(x: l, y: t, width: rt - l, height: bt - t)
                let nc = try c.u16()
                var chans: [(Int, Int)] = []
                for _ in 0..<nc { chans.append((try c.i16(), try c.len(large: large))) }
                guard try c.fourCC() == "8BIM" else { fail("layer \(i): blend signature"); return }
                let key = try c.fourCC()
                if !BlendMode.allCases.contains(where: { $0.psdKey == key }) { fail("layer \(i): blend key '\(key)'") }
                _ = try c.u8()
                let clip = try c.u8()
                if clip > 1 { fail("layer \(i): clipping \(clip)") }
                _ = try c.u8()
                if try c.u8() != 0 { fail("layer \(i): filler") }
                let extraLen = try c.u32()
                var e = try c.sub(extraLen)
                let mLen = try e.u32()
                var m = try e.sub(mLen)
                var maskRect: IRect? = nil, realRect: IRect? = nil
                if mLen > 0 {
                    func rect() throws -> IRect { let t = try m.i32(), l = try m.i32(), b = try m.i32(), r = try m.i32(); return IRect(x: l, y: t, width: max(0, r - l), height: max(0, b - t)) }
                    maskRect = try rect()
                    let def = try m.u8(), flags = try m.u8()
                    if def != 0 && def != 255 { fail("layer \(i): mask default \(def)") }
                    if flags & 0x10 != 0 {
                        let p = try m.u8()
                        if p & 1 != 0 { _ = try m.u8() }
                        if p & 2 != 0 { let f = try m.f64(); if !f.isFinite { fail("layer \(i): mask feather") } }
                        if p & 4 != 0 { _ = try m.u8() }
                        if p & 8 != 0 { _ = try m.f64() }
                    }
                    if mLen == 20 { _ = try m.u16() } else {
                        _ = try m.u8(); _ = try m.u8()
                        realRect = try rect()
                    }
                    if !m.atEnd { fail("layer \(i): \(m.remaining) stray mask bytes") }
                }
                let br = try e.u32()
                if br != 40 { fail("layer \(i): blending ranges \(br) bytes") }
                try e.skip(br)
                let pname = try e.pascal(pad: 4)
                var blocks: [String: Range<Int>] = [:]
                var name = pname
                while !e.atEnd {
                    guard try e.fourCC() == "8BIM" else { fail("layer \(i): block signature"); break }
                    let k = try e.fourCC()
                    let n = (large && PSDExport.longKeys.contains(k)) ? try e.u64() : try e.u32()
                    if n % 4 != 0 { fail("layer \(i): '\(k)' length \(n) not padded to 4") }
                    let rng = try e.take(n)
                    if blocks[k] != nil { fail("layer \(i): duplicate '\(k)'") }
                    blocks[k] = rng
                    rep.blockKeys[k, default: 0] += 1
                    if let err = checkBlock(k, b, rng) { fail("layer \(i) '\(pname)': '\(k)' \(err)") }
                    if k == "luni" { var lc = PSDCursor(b, rng); name = (try? lc.unicode()) ?? name }
                }
                if let s = blocks["lsct"] {
                    var sc = PSDCursor(b, s)
                    let type = try sc.u32()
                    if type == 3 { open += 1 } else if type == 1 || type == 2 { open -= 1; if open < 0 { fail("group closes before it opens") } }
                }
                if blocks["luni"] == nil { fail("layer \(i): no 'luni'") }
                if blocks["lyid"] == nil { fail("layer \(i): no 'lyid'") }
                recs.append((rect, chans, blocks, maskRect, realRect, name))
            }
            if open != 0 { fail("\(open) group(s) not closed") }
            rep.layerCount += count
            // channel data
            let bps = depth / 8
            for (i, rec) in recs.enumerated() {
                for (id, len) in rec.1 {
                    var cc = try c.sub(len)
                    let r: IRect = id == -2 ? (rec.3 ?? .zero) : (id == -3 ? (rec.4 ?? .zero) : rec.0)
                    let comp = try cc.u16()
                    if r.isEmpty { if len != 2 { fail("layer \(i) channel \(id): \(len) bytes for an empty rectangle") }; continue }
                    switch comp {
                    case 0: if cc.remaining != r.width * r.height * bps { fail("layer \(i) channel \(id): raw size") }
                    case 1:
                        var counts: [Int] = []
                        for _ in 0..<r.height { counts.append(large ? try cc.u32() : try cc.u16()) }
                        var row = [UInt8](repeating: 0, count: r.width * bps)
                        for n in counts { let rng = try cc.take(n); if !unpackExactly(b, rng, &row) { fail("layer \(i) channel \(id): bad row"); break } }
                        if !cc.atEnd { fail("layer \(i) channel \(id): \(cc.remaining) stray bytes") }
                    case 2, 3:
                        let rng = try cc.take(cc.remaining)
                        if PSDImporter.inflate(b, rng, expected: r.width * r.height * bps) == nil { fail("layer \(i) channel \(id): ZIP data") }
                    default: fail("layer \(i) channel \(id): compression \(comp)")
                    }
                }
            }
            while !c.atEnd { if try c.u8() != 0 { fail("layer info padding"); break } }
        } catch {
            rep.problems.append("layer info truncated: \(error)")
        }
    }

    /// nil when the block's payload is well formed and exactly as long as declared (allowing ≤ 3 zero pad bytes).
    static func checkBlock(_ key: String, _ b: [UInt8], _ r: Range<Int>) -> String? {
        let d = Data(b[r])
        func consumed(_ n: Int) -> String? {
            guard n <= d.count else { return "overruns its length (\(n) > \(d.count))" }
            let rest = d.dropFirst(n)
            if rest.count > 3 { return "has \(rest.count) bytes of trailing garbage" }
            if rest.contains(where: { $0 != 0 }) { return "padding is not zero" }
            return nil
        }
        func versioned(_ skip: Int, _ prefix: [UInt32] = []) -> String? {
            var dr = PSDDescriptorReader(d)
            do {
                try dr.skip(skip)
                for p in prefix { guard try dr.u32() == p else { return "bad version" } }
                guard try dr.u32() == 16 else { return "descriptor version" }
                _ = try dr.descriptor()
                return consumed(dr.pos)
            } catch { return "descriptor does not parse: \(error)" }
        }
        func fixed(_ n: Int) -> String? { consumed(n) }
        switch key {
        case "CgEd", "vibA", "blwh", "SoCo", "GdFl", "PtFl", "vstk", "artb": return versioned(0)
        case "vogk": return versioned(0, [1])
        case "lfx2": return versioned(0, [0])
        case "SoLd", "SoLE":
            guard d.prefix(4) == Data("soLD".utf8) else { return "bad signature" }
            return versioned(4, [4])
        case "PlLd":
            var c = PSDCursor(b, r)
            do {
                guard try c.fourCC() == "plcL", try c.u32() == 3 else { return "bad header" }
                _ = try c.pascal(pad: 1)
                try c.skip(16 + 64)
                guard try c.u32() == 0, try c.u32() == 16 else { return "warp version" }
                var dr = PSDDescriptorReader(c.data(c.pos..<c.end))
                _ = try dr.descriptor()
                return consumed(c.pos - r.lowerBound + dr.pos)
            } catch { return "does not parse: \(error)" }
        case "TySh":
            var c = PSDCursor(b, r)
            do {
                guard try c.u16() == 1 else { return "version" }
                for _ in 0..<6 { let v = try c.f64(); if !v.isFinite { return "transform not finite" } }
                guard try c.u16() == 50 else { return "text version" }
                var dr = PSDDescriptorReader(c.data(c.pos..<c.end))
                guard try dr.u32() == 16 else { return "descriptor version" }
                let td = try dr.descriptor()
                guard case .data(_, let ed)? = td["EngineData"] else { return "no EngineData" }
                var p = PSDEngineParser([UInt8](ed))
                let v = try p.value()
                if v["EngineDict"] == nil || v["ResourceDict"] == nil { return "engine data lacks EngineDict / ResourceDict" }
                try dr.skip(2)
                guard try dr.u32() == 16 else { return "warp version" }
                _ = try dr.descriptor()
                try dr.skip(16)
                return consumed(c.pos - r.lowerBound + dr.pos)
            } catch { return "does not parse: \(error)" }
        case "vmsk":
            guard d.count >= 8 + 52 else { return "too short" }
            return consumed(8 + (d.count - 8) / 26 * 26)
        case "luni":
            var c = PSDCursor(b, r)
            guard let n = try? c.u32() else { return "short" }
            return consumed(4 + n * 2)
        case "lyid", "clbl", "infx", "knko", "lspf", "iOpa", "lmgm", "vmgm", "post", "thrs": return fixed(4)
        case "lclr", "brit": return fixed(8)
        case "lsct": return d.count == 4 || d.count == 16 ? nil : "length \(d.count)"
        case "brst": return d.count % 4 == 0 ? nil : "length"
        case "levl": return fixed(2 + 29 * 10)
        case "hue2": return fixed(4 + 12 + 6 * 14)
        case "blnc": return fixed(20)
        case "selc": return fixed(4 + 8 + 9 * 8)
        case "mixr": return fixed(4 + 4 * 10)
        case "phfl": return fixed(2 + 2 + 8 + 4 + 2)
        case "expA": return fixed(2 + 12)
        case "nvrt": return fixed(0)
        case "curv":
            var c = PSDCursor(b, r)
            do {
                _ = try c.u8()
                guard try c.u16() == 1 else { return "version" }
                let mask = try c.u32()
                var n = 0
                for ch in 0..<32 where mask & (1 << ch) != 0 { n += 1; let k = try c.u16(); try c.skip(k * 4) }
                guard try c.fourCC() == "Crv ", try c.u16() == 4, try c.u32() == n else { return "'Crv ' extension" }
                for _ in 0..<n { _ = try c.u16(); let k = try c.u16(); try c.skip(k * 4) }
                return consumed(c.pos - r.lowerBound)
            } catch { return "does not parse: \(error)" }
        case "grdm":
            var c = PSDCursor(b, r)
            do {
                guard try c.u16() == 1 else { return "version" }
                try c.skip(2)
                _ = try c.unicode()
                let nc = try c.u16(); try c.skip(nc * 20)
                let nt = try c.u16(); try c.skip(nt * 10)
                try c.skip(2 + 2 + 2 + 2 + 4 + 2 + 2 + 4 + 2 + 8 + 8 + 2)
                return consumed(c.pos - r.lowerBound)
            } catch { return "does not parse: \(error)" }
        default:
            return "unknown key"
        }
    }
}
