import Foundation
import CoreGraphics
import ImageIO
import ImageCratCore

// Smart objects: the layer's placement ('SoLd' / 'SoLE' / 'PlLd') plus the embedded or linked file it shows
// (global 'lnk2' / 'lnkD' / 'lnk3' / 'lnkE' blocks).

enum PSDSmart {
    // MARK: Linked-layer data

    static func links(_ c0: PSDCursor, into out: inout [String: PSDLinkedFile]) {
        var c = c0
        while c.remaining >= 8, out.count < 4096 {
            guard let len = try? c.u64(), len >= 16, len <= c.remaining, var e = try? c.sub(len) else { break }
            let pad = (4 - len % 4) % 4
            if pad <= c.remaining { try? c.skip(pad) }
            guard let type = try? e.fourCC(), let version = try? e.u32(), (1...16).contains(version), let id = try? e.pascal(pad: 1),
                  let name = try? e.unicode(), let fileType = try? e.fourCC(), (try? e.skip(4)) != nil,
                  let dataLen = try? e.u64(), let hasDesc = try? e.u8() else { continue }
            var link = PSDLinkedFile(id: id, name: name, fileType: fileType, data: nil, externalPath: nil)
            func descriptor() -> PSDDescriptor? {
                var dr = PSDDescriptorReader(e.data(e.pos..<e.end))
                guard (try? dr.u32()) == 16, let d = try? dr.descriptor() else { return nil }
                try? e.skip(dr.pos)
                return d
            }
            if hasDesc != 0, descriptor() == nil { out[id] = link; continue }
            switch type {
            case "liFD":
                if dataLen <= e.remaining { link.data = try? e.take(dataLen) }
            case "liFE":
                if let d = descriptor() { link.externalPath = d.string("fullPath") ?? d.string("originalPath") ?? d.string("relPath") }
            default: break
            }
            if !id.isEmpty { out[id] = link }
        }
    }

    // MARK: Layer

    struct Placement {
        var id = ""
        var quad: Quad
        var warp: PSDDescriptor? = nil
        var filters: PSDDescriptor? = nil
        var size: CGSize? = nil
    }

    static func placement(_ r: PSDRecord, _ imp: PSDImporter) -> Placement? {
        func quad(_ v: [Double]) -> Quad? {
            guard v.count == 8, v.allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { return nil }
            return Quad(tl: CGPoint(x: v[0], y: v[1]), tr: CGPoint(x: v[2], y: v[3]), br: CGPoint(x: v[4], y: v[5]), bl: CGPoint(x: v[6], y: v[7]))
        }
        for key in ["SoLd", "SoLE"] {
            guard let b = r.block(key), let d = imp.descriptor(b, skip: 8) else { continue }
            func list(_ k: String) -> [Double] { (d.list(k) ?? []).compactMap(\.doubleValue) }
            guard let q = quad(list("nonAffineTransform")) ?? quad(list("Trnf")) else { continue }
            var p = Placement(id: d.string("Idnt") ?? "", quad: q, warp: d.object("warp"), filters: d.object("filterFX"))
            if let s = d.object("Sz  "), let w = s.double("Wdth"), let h = s.double("Hght"), w > 0, h > 0, w < 1e7, h < 1e7 { p.size = CGSize(width: w, height: h) }
            return p
        }
        // older files: placed-layer block only
        guard let b = r.block("PlLd") else { return nil }
        var c = PSDCursor(imp.bytes, b)
        guard (try? c.fourCC()) == "plcL", (try? c.u32()) == 3, let id = try? c.pascal(pad: 1), (try? c.skip(16)) != nil else { return nil }
        var v: [Double] = []
        for _ in 0..<8 { if let x = try? c.f64() { v.append(x) } }
        guard let q = quad(v) else { return nil }
        var p = Placement(id: id, quad: q)
        if (try? c.skip(4)) != nil { p.warp = imp.descriptor(c.pos..<c.end) }
        return p
    }

    static func layer(_ r: PSDRecord, _ imp: PSDImporter) -> Layer? {
        let stored = imp.pixels(r)
        /// The picture Photoshop rendered, wrapped as a smart object so the layer keeps its kind.
        func fallback(_ why: String, name: String) -> Layer? {
            guard let stored else {
                imp.report.add(.skipped, layer: r.name, feature: "Smart object", detail: why + " The layer has no pixels and was left out.")
                return nil
            }
            imp.report.add(.flattened, layer: r.name, feature: "Smart object", detail: why + " The smart object holds the pixels Photoshop rendered.")
            let so = SmartObjectContent(source: .image(stored), quad: Quad(rect: r.rect.cgRect), sourceName: name.isEmpty ? r.name : name)
            return Layer(name: r.name, content: .smartObject(so))
        }
        guard let p = placement(r, imp) else { return fallback("The placement data could not be read.", name: "") }
        let link = imp.links[p.id]
        let fileName = link?.name ?? ""

        var source: SmartSource? = nil
        var what = ""
        var linkedURL: URL? = nil
        if let range = link?.data {
            (source, what) = decode(imp.bytes, range, name: fileName, size: p.size, quad: p.quad, imp)
        } else if let path = link?.externalPath, let url = resolve(path, imp.baseURL), let d = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let b = [UInt8](d)
            (source, what) = decode(b, 0..<b.count, name: url.lastPathComponent, size: p.size, quad: p.quad, imp)
            if source != nil { linkedURL = url; what = "linked " + what }
        } else if link?.externalPath != nil {
            return fallback("The linked file “\(fileName)” was not found.", name: fileName)
        } else {
            return fallback("The embedded file is missing from the document.", name: fileName)
        }
        guard let src = source else { return fallback("“\(fileName)” is a file type ImageCrat cannot open (\(what)).", name: fileName) }

        var so = SmartObjectContent(source: src, quad: p.quad, sourceName: fileName.isEmpty ? r.name : fileName)
        if let url = linkedURL {
            so.linkedURL = url
            so.linkedModified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        }
        // Warp
        switch warp(p, src.size) {
        case .none: break
        case .mesh(let m): so.warp = m
        case .unsupported(let why): return fallback(why, name: fileName)
        }
        // Smart filters
        var filterNote: String? = nil
        if let fx = p.filters, let list = fx.list("filterFXList"), !list.isEmpty {
            var mapped: [FilterInstance] = []
            var names: [String] = []
            for item in list {
                guard let f = item.objectValue else { continue }
                let on = f.bool("enab") ?? true
                let name = f.string("Nm  ") ?? "Filter"
                if let inst = filter(f) { var i = inst; i.enabled = on; mapped.append(i) } else if on { names.append(name) }
            }
            if !names.isEmpty && (fx.bool("enab") ?? true) {
                let list = names.map { "“\($0)”" }.joined(separator: ", ")
                return fallback(names.count == 1 ? "Smart filter \(list) has no ImageCrat equivalent." : "Smart filters \(list) have no ImageCrat equivalent.", name: fileName)
            }
            so.filters = mapped.reversed()   // Photoshop lists the top filter first; Lumen applies bottom → top
            so.filtersEnabled = fx.bool("enab") ?? true
            if !mapped.isEmpty { filterNote = "\(mapped.count) smart filter\(mapped.count == 1 ? "" : "s") (\(mapped.map(\.kind.displayName).joined(separator: ", "))); the filter mask is not read" }
        }
        var detail = what
        if so.warp != nil { detail += ", warped" }
        if !p.quad.isAffine { detail += ", perspective" }
        imp.report.add(.editable, layer: r.name, feature: "Smart object", detail: detail)
        if let n = filterNote { imp.report.add(.substituted, layer: r.name, feature: "Smart filters", detail: n) }
        return Layer(name: r.name, content: .smartObject(so))
    }

    static func resolve(_ path: String, _ base: URL?) -> URL? {
        var candidates: [URL] = []
        if path.hasPrefix("file://"), let u = URL(string: path) { candidates.append(u) }
        if path.hasPrefix("/") { candidates.append(URL(fileURLWithPath: path)) }
        if let base, !path.hasPrefix("/"), !path.contains("://") { candidates.append(base.appendingPathComponent(path)) }
        if let base { candidates.append(base.appendingPathComponent((path as NSString).lastPathComponent.removingPercentEncoding ?? path)) }
        return candidates.first { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Embedded files

    /// Reads the Photoshop documents embedded in smart objects ahead of the layer walk, several at a time (each is a
    /// whole file to decode). One result per layer that shows it, so no two layers share pixel buffers.
    static func prefetch(_ imp: PSDImporter) {
        guard imp.nesting < PSDImporter.maxNesting else { return }
        var jobs: [(Range<Int>, String)] = []
        for r in imp.records where r.section == nil && (r.has("SoLd") || r.has("SoLE") || r.has("PlLd")) {
            guard let p = placement(r, imp), let link = imp.links[p.id], let range = link.data, range.count > 8, range.upperBound <= imp.bytes.count,
                  imp.bytes[range.lowerBound..<(range.lowerBound + 4)].elementsEqual([0x38, 0x42, 0x50, 0x53]) else { continue }
            jobs.append((range, link.name))
        }
        guard jobs.count > 1 else { return }
        var results = [PSDImporter.Result?](repeating: nil, count: jobs.count)
        results.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                let (range, name) = jobs[k]
                (base + k).pointee = try? PSDImporter.read(data: Data(imp.bytes[range]), name: name, nesting: imp.nesting + 1, baseURL: imp.baseURL)
            }
        }
        for (k, j) in jobs.enumerated() { if let r = results[k] { imp.prefetched[j.0.lowerBound, default: []].append(r) } }
    }

    /// Decodes an embedded file: a PSD / PSB stays a layered document, images become pixels, PDF / AI art is rendered.
    static func decode(_ bytes: [UInt8], _ range: Range<Int>, name: String, size: CGSize?, quad: Quad, _ imp: PSDImporter) -> (SmartSource?, String) {
        guard range.count > 8, range.upperBound <= bytes.count else { return (nil, "empty file") }
        let head = Array(bytes[range.lowerBound..<(range.lowerBound + 8)])
        let data = Data(bytes[range])
        if head.starts(with: [0x38, 0x42, 0x50, 0x53]) {   // 8BPS
            guard imp.nesting < PSDImporter.maxNesting else { return (nil, "smart objects nested too deeply") }
            let pre = imp.prefetched[range.lowerBound]?.popLast()
            guard let res = pre ?? (try? PSDImporter.read(data: data, name: name, nesting: imp.nesting + 1, baseURL: imp.baseURL)) else { return (nil, "unreadable Photoshop document") }
            for it in res.report.items where it.status != .info || !it.layer.isEmpty {
                imp.report.add(it.status, layer: it.layer.isEmpty ? name : "\(name) ▸ \(it.layer)", feature: it.feature, detail: it.detail)
            }
            imp.report.missingFonts.formUnion(res.report.missingFonts)
            for p in res.patterns { imp.patterns[p.id] = p; imp.usePattern(p.id) }
            let st = res.state
            let kind = "embedded Photoshop document “\(name)” (\(st.width) × \(st.height) px, \(st.allLayers.count) layer\(st.allLayers.count == 1 ? "" : "s"))"
            if st.layers.count == 1, let rr = st.layers[0].raster, rr.origin == .zero, rr.buffer.width == st.width, rr.buffer.height == st.height,
               st.layers[0].mask == nil, st.layers[0].vectorMask == nil, !st.layers[0].effects.hasAny, st.layers[0].opacity >= 0.999 {
                return (.image(rr.buffer), kind)
            }
            return (.document(st), kind)
        }
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) {   // %PDF (also Illustrator files)
            guard let buf = renderPDF(data, quad: quad) else { return (nil, "PDF / Illustrator art") }
            return (.image(buf), "embedded vector art “\(name)” rendered at \(buf.width) × \(buf.height) px")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, PSDLimits.plausible(w, h) else {
            return (nil, (name as NSString).pathExtension.isEmpty ? "unknown format" : "." + (name as NSString).pathExtension)
        }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        var cg: CGImage?
        if orientation != 1 {
            let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
        }
        guard let img = cg ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { return (nil, "undecodable image") }
        let type = (CGImageSourceGetType(src) as String?).map { ($0 as NSString).pathExtension.uppercased() } ?? "image"
        return (.image(PixelBuffer(cgImage: img)), "embedded \(type) “\(name)” (\(img.width) × \(img.height) px)")
    }

    /// First page of a PDF at the resolution the placement needs (at least its on-canvas size).
    static func renderPDF(_ data: Data, quad: Quad) -> PixelBuffer? {
        guard let prov = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(prov), let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { return nil }
        let want = max(quad.tl.distance(to: quad.tr), quad.bl.distance(to: quad.br), 1)
        let scale = min(max(want / box.width, 1), 8192 / max(box.width, box.height))
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        guard PSDLimits.plausible(w, h) else { return nil }
        let buf = PixelBuffer(width: w, height: h)
        func draw(_ ctx: CGContext) {
            ctx.saveGState()
            // the buffer context is y-down; PDF pages are y-up
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        }
        // CMYK art (Illustrator files in CMYK mode) is converted with black point compensation like Photoshop does;
        // drawn at 16 bits first so stretching the dark end does not band
        if let cmyk = cmykSpace(page), let bp = PSDColorConverter.blackPoint(cmyk),
           let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: sRGBSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue), let p = ctx.data {
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // match the buffer's y-down context
            draw(ctx)
            PSDColorConverter.compensate(p.assumingMemoryBound(to: UInt16.self), srcRowWords: ctx.bytesPerRow / 2, into: buf, bp)
            return buf
        }
        draw(buf.context)
        buf.markDirty()
        return buf
    }

    /// The CMYK profile a PDF page draws with: its ICC-based CMYK colour spaces, when it uses no RGB ones.
    static func cmykSpace(_ page: CGPDFPage) -> CGColorSpace? {
        guard let pd = page.dictionary else { return nil }
        var found: CGColorSpace? = nil
        var rgb = false
        func scan(_ res: CGPDFDictionaryRef, depth: Int) {
            var csd: CGPDFDictionaryRef? = nil
            if CGPDFDictionaryGetDictionary(res, "ColorSpace", &csd), let csd {
                CGPDFDictionaryApplyBlock(csd, { _, obj, _ in
                    var name: UnsafePointer<CChar>? = nil
                    if CGPDFObjectGetValue(obj, .name, &name), let name {
                        if ["DeviceRGB", "CalRGB"].contains(String(cString: name)) { rgb = true }
                        return true
                    }
                    var arr: CGPDFArrayRef? = nil
                    guard CGPDFObjectGetValue(obj, .array, &arr), let arr, CGPDFArrayGetCount(arr) >= 2 else { return true }
                    var kind: UnsafePointer<CChar>? = nil
                    guard CGPDFArrayGetName(arr, 0, &kind), let kind else { return true }
                    switch String(cString: kind) {
                    case "ICCBased":
                        var st: CGPDFStreamRef? = nil
                        guard CGPDFArrayGetStream(arr, 1, &st), let st, let sd = CGPDFStreamGetDictionary(st) else { return true }
                        var n: CGPDFInteger = 0
                        _ = CGPDFDictionaryGetInteger(sd, "N", &n)
                        if n == 3 { rgb = true }
                        var fmt = CGPDFDataFormat.raw
                        if n == 4, found == nil, let d = CGPDFStreamCopyData(st, &fmt), fmt == .raw, let cs = CGColorSpace(iccData: d), cs.model == .cmyk { found = cs }
                    case "CalRGB", "Lab": rgb = true
                    default: break
                    }
                    return true
                }, nil)
            }
            // form XObjects carry their own resources
            var xd: CGPDFDictionaryRef? = nil
            guard depth < 2, CGPDFDictionaryGetDictionary(res, "XObject", &xd), let xd else { return }
            CGPDFDictionaryApplyBlock(xd, { _, obj, _ in
                var st: CGPDFStreamRef? = nil
                if CGPDFObjectGetValue(obj, .stream, &st), let st, let sd = CGPDFStreamGetDictionary(st) {
                    var r: CGPDFDictionaryRef? = nil
                    if CGPDFDictionaryGetDictionary(sd, "Resources", &r), let r { scan(r, depth: depth + 1) }
                }
                return true
            }, nil)
        }
        var res: CGPDFDictionaryRef? = nil
        if CGPDFDictionaryGetDictionary(pd, "Resources", &res), let res { scan(res, depth: 0) }
        return rgb ? nil : found
    }

    // MARK: Warp

    enum WarpResult { case none, mesh(MeshWarpData), unsupported(String) }

    /// Photoshop's custom warp is a bicubic Bézier patch over the source bounds; it is sampled into a mesh in
    /// document space. Preset warps (Arc, Flag…) are generated by Photoshop and have no stored mesh.
    static func warp(_ p: Placement, _ srcSize: CGSize) -> WarpResult {
        guard let w = p.warp, let style = w.enumValue("warpStyle"), style != "warpNone" else { return .none }
        guard style == "warpCustom" else {
            if (w.double("warpValue") ?? 0) == 0, (w.double("warpPerspective") ?? 0) == 0, (w.double("warpPerspectiveOther") ?? 0) == 0 { return .none }
            return .unsupported("The “\(style.replacingOccurrences(of: "warp", with: ""))” warp preset cannot be reproduced exactly.")
        }
        guard let env = w.object("customEnvelopeWarp"), case .objectArray(_, let mp)? = env["meshPoints"],
              case .unitFloats(_, let xs)? = mp["Hrzn"], case .unitFloats(_, let ys)? = mp["Vrtc"],
              (w.double("uOrder") ?? 4) == 4, (w.double("vOrder") ?? 4) == 4, xs.count == 16, ys.count == 16,
              (xs + ys).allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else {
            return .unsupported("The warp uses a mesh layout (split warp) ImageCrat cannot read.")
        }
        var bounds = CGRect(origin: .zero, size: p.size ?? srcSize)
        if let b = w.object("bounds"), let t = b.double("Top "), let l = b.double("Left"), let bt = b.double("Btom"), let rt = b.double("Rght"),
           [t, l, bt, rt].allSatisfy({ $0.isFinite }), rt > l, bt > t { bounds = CGRect(x: l, y: t, width: rt - l, height: bt - t) }
        guard bounds.width > 0, bounds.height > 0 else { return .none }
        guard bounds.width < 1e7, bounds.height < 1e7, abs(bounds.minX) < 1e7, abs(bounds.minY) < 1e7 else { return .unsupported("The warp bounds are out of range.") }
        let pts = (0..<16).map { CGPoint(x: xs[$0], y: ys[$0]) }
        // untouched custom warp: the control points are still the regular grid
        let tol = max(bounds.width, bounds.height) * 1e-4 + 1e-6
        let identity = (0..<16).allSatisfy { i in
            let reg = CGPoint(x: bounds.minX + bounds.width * CGFloat(i % 4) / 3, y: bounds.minY + bounds.height * CGFloat(i / 4) / 3)
            return reg.distance(to: pts[i]) < tol
        }
        if identity { return .none }
        guard let H = Homography(from: Quad(rect: bounds), to: p.quad) else { return .unsupported("The warp placement is degenerate.") }
        func bern(_ t: CGFloat) -> [CGFloat] { let u = 1 - t; return [u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t] }
        let n = 17
        var from: [CGPoint] = [], to: [CGPoint] = []
        for j in 0..<n {
            let v = CGFloat(j) / CGFloat(n - 1), bv = bern(v)
            for i in 0..<n {
                let u = CGFloat(i) / CGFloat(n - 1), bu = bern(u)
                var q = CGPoint.zero
                for rr in 0..<4 { for cc in 0..<4 { q = q + pts[rr * 4 + cc] * (bv[rr] * bu[cc]) } }
                from.append(H.apply(CGPoint(x: bounds.minX + bounds.width * u, y: bounds.minY + bounds.height * v)))
                to.append(H.apply(q))
            }
        }
        guard (from + to).allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1e7 && abs($0.y) < 1e7 }) else { return .unsupported("The warp mesh is out of range.") }
        return .mesh(MeshWarpData(from: MeshGrid(cols: n, rows: n, positions: from), to: MeshGrid(cols: n, rows: n, positions: to)))
    }

    // MARK: Smart filters

    /// The few Photoshop filters whose settings map one-to-one onto a Lumen smart filter.
    static func filter(_ f: PSDDescriptor) -> FilterInstance? {
        guard let d = f.object("Fltr") else { return nil }
        var inst: FilterInstance
        switch d.classID {
        case "GsnB":
            guard let r = d.double("Rds "), r.isFinite else { return nil }
            inst = FilterInstance(kind: .gaussianBlur)
            inst.values["radius"] = clamp(r, 0, 250)
        default: return nil
        }
        if let bo = f.object("blendOptions") {
            if let o = bo.double("Opct"), o.isFinite { inst.opacity = clamp(o / 100, 0, 1) }
            if let m = bo.enumValue("Md  "), let mode = BlendMode(descriptorKey: m) { inst.blendMode = mode }
        }
        return inst
    }
}
