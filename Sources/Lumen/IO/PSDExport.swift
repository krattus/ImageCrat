import Foundation
import CoreImage
import CoreGraphics
import Compression
import ImageCratCore

// MARK: - PSD / PSB export
//
// Writes each Lumen layer kind the way Photoshop stores it: adjustment and fill layers, shapes and vector masks, type
// ('TySh' + engine data), smart objects with their embedded file, groups and artboards, masks, blending options and
// document resources. Every layer also keeps its rendered pixels and the file carries the flattened composite, so a
// reader that ignores the live data still shows the right picture. Whatever Photoshop has no slot for is baked into
// pixels or approximated, and listed in `PSDExport.lastNotes`; the exact Lumen settings of such layers travel in a
// private resource (`PSDExportLumen`) so Lumen re-opens its own files unchanged.

struct PSDExportNote: Equatable {
    enum Status: String { case editable, approximated, baked }
    var layer: String
    var feature: String
    var status: Status
    var detail: String
}

/// A layer mask as written: a pixel (user) mask, or the rendering of a vector mask.
struct PSDWriteMask {
    var rect: IRect
    var plane: [UInt8]
    var defaultColor: UInt8
    var disabled = false
    var unlinked = false
    var density: UInt8? = nil
    var feather: Double? = nil
}

struct PSDWriteRecord {
    var name: String
    var rect = IRect.zero
    /// R, G, B planes of `rect` (empty: the layer has no pixels, like groups and adjustment layers).
    var planes: [[UInt8]] = []
    var alpha: [UInt8] = []
    /// 16-bit documents: R, G, B, A of `rect` rendered at 16 bits (nil: the 8-bit planes are widened).
    var wide: [[UInt16]]? = nil
    var blendKey = "norm"
    var opacity: UInt8 = 255
    var clipping: UInt8 = 0
    /// Bit 3 is set by every current Photoshop; bit 4 marks pixel data that does not define the appearance.
    var flags: UInt8 = 0x08
    var userMask: PSDWriteMask? = nil
    /// Photoshop's rendering of the vector mask: channel -2 with mask flag bit 3 (the user mask then moves to -3).
    var vectorMask: PSDWriteMask? = nil
    var blendRanges = Data()
    var blocks: [(String, Data)] = []
    var layerID: UInt32 = 0
    var linkID: UUID? = nil

    init(name: String) { self.name = name }
}

enum PSDExport {
    /// What the last `write` approximated or baked (layer, feature, why).
    static var lastNotes: [PSDExportNote] = []
    /// Lumen-only settings travel in a private image resource (tests switch it off to exercise the Photoshop data).
    static var writeLumenData = true
    /// Linked smart objects keep a reference to their file (a 'liFE' record in the global 'lnkE' block, placed with
    /// 'SoLE', the way Photoshop stores linked layers) instead of an embedded copy. A link whose file is missing is
    /// embedded instead.
    static var writeExternalLinks = true
    /// Document-level text engine data ('Txt2': fonts, styles, stories and their line layout) next to each type
    /// layer's 'TySh', so Photoshop takes the stored layout instead of asking to update the text layers.
    static var writeTextEngineData = true
    /// Folder of the file being written (linked smart objects store their path relative to it).
    static var outputFolder: URL? = nil
    /// Sample files written for another place: external links are recorded as if the document and its linked files
    /// were in this folder (the files' size and date are still read where they are now).
    static var recordedFolder: URL? = nil
    static let maxNesting = 4

    static func write(_ st: DocumentState, to url: URL, large: Bool = false) throws {
        outputFolder = url.deletingLastPathComponent()
        defer { outputFolder = nil }
        let (data, notes) = try encode(st, large: large, nesting: 0)
        lastNotes = notes
        try data.write(to: url, options: .atomic)
    }

    static func encode(_ st0: DocumentState, large: Bool, nesting: Int) throws -> (Data, [PSDExportNote]) {
        let st = RepeaterActions.expandedForExport(st0)   // Layout module: live repeaters are written as real layers
        guard st.width > 0, st.height > 0 else { throw DocumentIOError.encodeFailed }
        let ctx = PSDExportContext(st, large: large, nesting: nesting)
        for l in st.layers { ctx.add(l) }
        return (try ctx.file(), ctx.notes)
    }

    // MARK: Shared encoders

    static func fin(_ v: Double, _ fallback: Double = 0) -> Double { v.isFinite ? v : fallback }
    static func byte(_ v: Double) -> UInt8 { UInt8(clamp(fin(v), 0, 1) * 255 + 0.5) }

    /// Premultiplied RGBA → straight R, G, B, A planes.
    static func planes(_ buf: PixelBuffer) -> [[UInt8]] {
        let w = buf.width, h = buf.height
        var r = [UInt8](repeating: 0, count: w * h), g = r, b = r, a = r
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = p + y * buf.bytesPerRow
            for x in 0..<w {
                let i = x * 4, o = y * w + x
                let al = Int(row[i + 3])
                a[o] = UInt8(al)
                if al == 255 || al == 0 { r[o] = row[i]; g[o] = row[i + 1]; b[o] = row[i + 2]; continue }
                r[o] = UInt8(min(255, (Int(row[i]) * 255 + al / 2) / al))
                g[o] = UInt8(min(255, (Int(row[i + 1]) * 255 + al / 2) / al))
                b[o] = UInt8(min(255, (Int(row[i + 2]) * 255 + al / 2) / al))
            }
        }
        return [r, g, b, a]
    }

    static func grayPlane(_ b: PixelBuffer) -> [UInt8] {
        let w = b.width, h = b.height
        var out = [UInt8](repeating: 0, count: w * h)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        if b.format == .gray {
            for y in 0..<h { for x in 0..<w { out[y * w + x] = p[y * b.bytesPerRow + x] } }
        } else {
            for y in 0..<h { for x in 0..<w { out[y * w + x] = p[y * b.bytesPerRow + x * 4] } }
        }
        return out
    }

    /// Bounds of the samples that differ from `background` in a w × h plane.
    static func bounds(_ plane: [UInt8], width w: Int, height h: Int, background: UInt8) -> IRect? {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        plane.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where p[row + x] != background {
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    if y < y0 { y0 = y }
                    y1 = y
                }
            }
        }
        return x1 < 0 ? nil : IRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    static func crop(_ plane: [UInt8], width w: Int, to r: IRect) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: r.width * r.height)
        for y in 0..<r.height {
            let s = (r.y + y) * w + r.x
            for x in 0..<r.width { out[y * r.width + x] = plane[s + x] }
        }
        return out
    }

    /// zlib stream (header + deflate + Adler-32), as Photoshop's ZIP channel compression expects.
    static func zlib(_ d: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: d.count + d.count / 8 + 1024)
        let n = d.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { o in
            compression_encode_buffer(o.baseAddress!, o.count, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
        } }
        var a: UInt32 = 1, b: UInt32 = 0
        for x in d { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        let ad = b << 16 | a
        return [0x78, 0x9C] + out.prefix(n) + [UInt8(ad >> 24), UInt8((ad >> 16) & 0xff), UInt8((ad >> 8) & 0xff), UInt8(ad & 0xff)]
    }

    /// One layer channel: compression word + data. 8-bit: PackBits; 16-bit: ZIP with prediction (per-row deltas of
    /// the big-endian samples), as Photoshop writes 16-bit layers, of `wide` or else of the widened 8-bit samples.
    static func channel(_ plane: [UInt8], width w: Int, height h: Int, depth: Int, large: Bool, wide: [UInt16]? = nil) -> Data {
        var out = BinaryWriter()
        guard w > 0, h > 0, plane.count >= w * h || (wide?.count ?? 0) >= w * h else { out.u16(0); return out.data }
        if depth == 16 {
            var bytes = [UInt8](repeating: 0, count: w * h * 2)
            for y in 0..<h {
                var prev: UInt16 = 0
                for x in 0..<w {
                    let i = y * w + x
                    let v: UInt16 = wide.map { $0[i] } ?? UInt16(plane[i]) * 257
                    let d = v &- prev
                    prev = v
                    bytes[i * 2] = UInt8(d >> 8); bytes[i * 2 + 1] = UInt8(d & 0xff)
                }
            }
            out.u16(3)
            out.bytes(zlib(bytes))
            return out.data
        }
        out.u16(1)
        var counts = BinaryWriter(), body = BinaryWriter()
        plane.withUnsafeBufferPointer { ptr in
            for y in 0..<h {
                let e = PackBits.encode(UnsafeBufferPointer(rebasing: ptr[(y * w)..<(y * w + w)]))
                if large { counts.u32(UInt32(e.count)) } else { counts.u16(UInt16(e.count)) }
                body.bytes(e)
            }
        }
        out.raw(counts.data); out.raw(body.data)
        return out.data
    }

    /// Straight (unpremultiplied) R, G, B, A planes of doc rect `r` of `image`, rendered at 16 bits per channel (in
    /// bands of rows, so only the planes are held in full).
    static func planes16(_ image: CIImage, docRect r: IRect, space: CanvasSpace) -> [[UInt16]] {
        let w = max(1, r.width), h = max(1, r.height)
        var R = [UInt16](repeating: 0, count: w * h), G = R, B = R, A = R
        let band = max(1, min(h, (1 << 22) / w))
        var px = [UInt16](repeating: 0, count: w * band * 4)
        var y0 = 0
        while y0 < h {
            let bh = min(band, h - y0)
            let ciRect = space.ciRect(IRect(x: r.x, y: r.y + y0, width: w, height: bh))
            let bg = CIImage.clearImage.cropped(to: ciRect)
            px.withUnsafeMutableBytes { p in
                RenderEngine.readbackContext.render(image.composited(over: bg), toBitmap: p.baseAddress!, rowBytes: w * 8, bounds: ciRect,
                                                    format: .RGBA16, colorSpace: sRGBSpace)
            }
            for j in 0..<(w * bh) {
                let i = y0 * w + j
                let a = UInt32(px[j * 4 + 3])
                A[i] = UInt16(a)
                if a == 65535 || a == 0 { R[i] = px[j * 4]; G[i] = px[j * 4 + 1]; B[i] = px[j * 4 + 2]; continue }
                R[i] = UInt16(min(65535, (UInt32(px[j * 4]) * 65535 + a / 2) / a))
                G[i] = UInt16(min(65535, (UInt32(px[j * 4 + 1]) * 65535 + a / 2) / a))
                B[i] = UInt16(min(65535, (UInt32(px[j * 4 + 2]) * 65535 + a / 2) / a))
            }
            y0 += bh
        }
        return [R, G, B, A]
    }

    static func crop16(_ plane: [UInt16], width w: Int, to r: IRect) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: r.width * r.height)
        for y in 0..<r.height {
            let s = (r.y + y) * w + r.x
            for x in 0..<r.width { out[y * r.width + x] = plane[s + x] }
        }
        return out
    }

    /// Tagged-block keys whose length field is 8 bytes in PSB files.
    static let longKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]

    static func u32(_ v: UInt32) -> Data { var w = BinaryWriter(); w.u32(v); return w.data }
    static func flag(_ on: Bool) -> Data { Data([on ? 1 : 0, 0, 0, 0]) }
}

// MARK: - Context

final class PSDExportContext {
    let st: DocumentState
    let sp: CanvasSpace
    let large: Bool
    let depth: Int
    let nesting: Int
    var records: [PSDWriteRecord] = []
    var notes: [PSDExportNote] = []
    var links: [PSDExportSmart.Link] = []
    var patternIDs: [String] = []
    var lumen: [PSDExportLumen.Entry] = []
    var nextLayerID: UInt32 = 1
    var textIndex = 0
    /// Type layers in 'TextIndex' order, for the document's 'Txt2'.
    var texts: [PSDExportText.Story] = []
    /// 16-bit rendering of the last `rendered` layer (doc rect, R G B A planes), picked up by `setPixels`.
    var wideRender: (IRect, [[UInt16]])? = nil

    init(_ st: DocumentState, large: Bool, nesting: Int) {
        self.st = st
        self.sp = CanvasSpace(width: st.width, height: st.height)
        self.large = large
        self.nesting = nesting
        depth = st.bitDepth == .eight ? 8 : 16   // 32-bit documents are written as 16-bit (Lumen keeps 8-bit pixels)
    }

    func note(_ l: Layer, _ feature: String, _ status: PSDExportNote.Status, _ detail: String) {
        notes.append(PSDExportNote(layer: l.name, feature: feature, status: status, detail: detail))
    }

    func usePattern(_ id: String) { if !patternIDs.contains(id) { patternIDs.append(id) } }

    // MARK: Layers

    func add(_ l: Layer) {
        switch l.content {
        case .group(let g):
            var divider = PSDWriteRecord(name: "</Layer group>")
            divider.flags = 0x18
            divider.layerID = takeID()
            divider.blocks = [("luni", luni(divider.name)), ("lyid", PSDExport.u32(divider.layerID)), ("lsct", PSDExport.u32(3))]
            divider.blendRanges = PSDExportContext.blendRanges(BlendIf())
            records.append(divider)
            for c in g.children { add(c) }
            group(l, g)
        case .adjustment(let a): adjustment(l, a)
        case .raster: pixelLayer(l)
        case .text(let t): text(l, t)
        case .shape(let s): shape(l, s)
        case .fill(let f): fill(l, f)
        case .smartObject(let so): smart(l, so)
        }
    }

    func takeID() -> UInt32 { defer { nextLayerID += 1 }; return nextLayerID }

    /// Rendered content of a non-pixel layer, without masks, layer style (written as 'lfx2'), opacity and blending,
    /// the way Photoshop stores a layer's own pixels. nil when nothing is visible on the canvas.
    func rendered(_ l: Layer) -> (PixelBuffer, IPoint)? {
        var tmp = l
        tmp.mask = nil
        tmp.vectorMask = nil
        tmp.opacity = 1; tmp.fillOpacity = 1; tmp.blendMode = .normal; tmp.isVisible = true; tmp.isClipped = false
        tmp.knockout = .none; tmp.blendIf = BlendIf(); tmp.channelR = true; tmp.channelG = true; tmp.channelB = true
        tmp.effects = LayerEffects()
        let img = Compositor.shared.layerAppearance(tmp, state: st)
        let rect = IRect(enclosing: sp.docRect(img.extent)).intersection(st.canvasRect)
        guard !rect.isEmpty else { return nil }
        let buf = RenderEngine.renderBuffer(img, docRect: rect, space: sp)
        guard let b = buf.opaqueBounds() else { return nil }
        let out = IRect(x: rect.x + b.x, y: rect.y + b.y, width: b.width, height: b.height)
        if depth == 16 { wideRender = (out, PSDExport.planes16(img, docRect: out, space: sp)) }
        if b == buf.bounds { return (buf, rect.origin) }
        return (buf.cropped(to: b), out.origin)
    }

    func setPixels(_ r: inout PSDWriteRecord, _ px: (PixelBuffer, IPoint)?) {
        let wide = wideRender
        wideRender = nil
        r.wide = nil
        guard let (buf, o) = px else { r.rect = .zero; r.planes = []; r.alpha = []; return }
        var buffer = buf, origin = o
        if let b = buffer.opaqueBounds(), b != buffer.bounds {
            buffer = buffer.cropped(to: b)
            origin = IPoint(x: origin.x + b.x, y: origin.y + b.y)
        } else if buffer.opaqueBounds() == nil {
            r.rect = .zero; r.planes = []; r.alpha = []; return
        }
        let pl = PSDExport.planes(buffer)
        r.rect = IRect(x: origin.x, y: origin.y, width: buffer.width, height: buffer.height)
        r.planes = [pl[0], pl[1], pl[2]]
        r.alpha = pl[3]
        // the 16-bit rendering of the same pixels, when this record shows what `rendered` drew
        if depth == 16, let (wr, planes) = wide, wr.intersection(r.rect) == r.rect {
            let local = IRect(x: r.rect.x - wr.x, y: r.rect.y - wr.y, width: r.rect.width, height: r.rect.height)
            r.wide = planes.map { PSDExport.crop16($0, width: wr.width, to: local) }
        }
    }

    func pixelLayer(_ l: Layer) {
        guard let rc = l.raster else { return }
        var r = PSDWriteRecord(name: l.name)
        setPixels(&r, (rc.buffer, rc.origin))
        finish(&r, l, kindBlocks: [])
    }

    // MARK: Groups

    func group(_ l: Layer, _ g: GroupContent) {
        var r = PSDWriteRecord(name: l.name)
        r.flags = 0x18
        var kind: [(String, Data)] = []
        var sect = BinaryWriter()
        sect.u32(g.isExpanded ? 1 : 2); sect.ascii("8BIM"); sect.ascii(l.blendMode.psdKey); sect.u32(0)
        kind.append(("lsct", sect.data))
        if let ab = g.artboard { kind.append(("artb", PSDExportVector.artboard(ab))) }
        finish(&r, l, kindBlocks: kind, group: true)
        if g.artboard != nil { note(l, "Artboard", .editable, "\(Int(g.artboard!.rect.width)) × \(Int(g.artboard!.rect.height)) px") }
    }

    // MARK: Adjustments

    func adjustment(_ l: Layer, _ a: AdjustmentSettings) {
        var r = PSDWriteRecord(name: l.name)
        let enc = PSDExportAdjust.encode(a)
        if let blocks = enc.blocks {
            r.flags = 0x18
            if let n = enc.note { note(l, a.kind.displayName, .approximated, n) } else { note(l, a.kind.displayName, .editable, "adjustment layer") }
            finish(&r, l, kindBlocks: blocks, adjustment: true)
            remember(l, r, lossy: enc.note != nil)
            return
        }
        // No Photoshop equivalent: a pixel layer holding the adjusted picture under it gives the same look.
        if let px = bakedAdjustment(l) {
            setPixels(&r, px)
            note(l, a.kind.displayName, .baked, enc.why ?? "no Photoshop adjustment layer")
        } else {
            note(l, a.kind.displayName, .baked, (enc.why ?? "no Photoshop adjustment layer") + " The picture under it could not be rendered; the layer is empty.")
        }
        var baked = l
        baked.fillOpacity = 1
        finish(&r, baked, kindBlocks: [])
        remember(l, r, lossy: true)
    }

    /// The image the adjustment produces from what is under it, in its own stacking context.
    func bakedAdjustment(_ l: Layer) -> (PixelBuffer, IPoint)? {
        var s = st
        if let p = s.layers.indexPath(of: l.id) {
            for k in 1...p.count { s.layers[path: Array(p.prefix(k))].isVisible = true }
        }
        var captured: CIImage? = nil
        var opts = Compositor.Options()
        opts.overrides[l.id] = { img in captured = img; return img }
        _ = Compositor.shared.composite(s, options: opts)
        guard let img = captured else { return nil }
        let buf = RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
        guard let b = buf.opaqueBounds() else { return nil }
        return (b == buf.bounds ? buf : buf.cropped(to: b), b.origin)
    }

    // MARK: Fill layers

    func fill(_ l: Layer, _ f: FillContent) {
        var r = PSDWriteRecord(name: l.name)
        if f.recipe != nil {
            setPixels(&r, rendered(l))
            note(l, "Recipe layer", .baked, "Node recipes have no Photoshop equivalent (and refer to other layers by id); the layer is written as pixels.")
            finish(&r, l, kindBlocks: [])
            remember(l, r, lossy: true)
            return
        }
        let paint = PSDExportVector.contentBlock(f.paint, refBounds: st.canvasCGRect, canvas: st.canvasCGRect, ctx: self)
        r.flags = 0x18
        setPixels(&r, rendered(l))
        if let n = paint.note { note(l, "Fill layer", .approximated, n) } else { note(l, "Fill layer", .editable, paint.what) }
        finish(&r, l, kindBlocks: [paint.block])
        remember(l, r, lossy: paint.note != nil)
    }

    // MARK: Shapes

    func shape(_ l: Layer, _ s: ShapeContent) {
        var r = PSDWriteRecord(name: l.name)
        var layer = l
        var lossy = false
        let path = s.path
        let pathBounds = path.bounds
        // A shape is defined by its vector mask in Photoshop: a second (Lumen) vector mask joins the pixel mask.
        if let vm = l.vectorMask, !vm.isEmpty, l.vectorMaskEnabled {
            if let img = Compositor.shared.maskImage(l, space: sp, raster: l.mask != nil, vector: true) {
                let rect = st.canvasRect.union(l.mask?.frame ?? .zero)
                let buf = RenderEngine.renderBuffer(img, docRect: rect, space: sp, format: .gray)
                var m = LayerMask(buffer: buf, origin: rect.origin, outsideValue: 0)
                m.isEnabled = true
                layer.mask = m
            }
            layer.vectorMask = nil
            note(l, "Vector mask", .approximated, "A shape layer has no separate vector mask in Photoshop; it is written as a pixel mask.")
            lossy = true
        }
        let fillPaint: PaintStyle = s.fill.isNone ? .color(.black) : s.fill
        let content = PSDExportVector.contentBlock(fillPaint, refBounds: pathBounds, canvas: st.canvasCGRect, ctx: self)
        var kind: [(String, Data)] = [content.block]
        kind.append(("vmsk", PSDExportVector.vectorMaskBlock(path, width: st.width, height: st.height, disabled: false)))
        if let live = PSDExportVector.origination(s) { kind.append(("vogk", live)) } else if s.geometry.isLivePrimitive {
            lossy = true
        }
        let stroke = PSDExportVector.strokeBlock(s.stroke, fillEnabled: !s.fill.isNone, ctx: self)
        kind.append(("vstk", stroke.block))
        r.flags = 0x18
        setPixels(&r, rendered(layer))
        r.vectorMask = renderVectorMask(path, disabled: false)
        var what = s.geometry.kindName
        if !s.fill.isNone { what += ", " + content.what }
        if !s.stroke.paint.isNone { what += ", stroke \(Int(s.stroke.width.rounded())) px" }
        let notesHere = [content.note, stroke.note].compactMap { $0 }
        if s.perspective != nil || !s.geometry.isPhotoshopPrimitive { lossy = true }
        if notesHere.isEmpty { note(l, "Shape", .editable, what) } else { for n in notesHere { note(l, "Shape", .approximated, n) } }
        if !s.geometry.isPhotoshopPrimitive { note(l, "Shape", .approximated, "\(s.geometry.kindName) settings are written as a path (Photoshop keeps the outline, not the \(s.geometry.kindName.lowercased()) parameters).") }
        finish(&r, layer, kindBlocks: kind, ownVectorMask: true)
        remember(l, r, lossy: lossy || !notesHere.isEmpty)
    }

    // MARK: Type

    func text(_ l: Layer, _ t: TextContent) {
        var r = PSDWriteRecord(name: l.name)
        let enc = PSDExportText.block(t, index: textIndex)
        textIndex += 1
        texts.append(enc.story)
        setPixels(&r, rendered(l))
        note(l, "Type", enc.notes.isEmpty ? .editable : .approximated, enc.notes.isEmpty ? "“\(t.text.prefix(30))”" : enc.notes.joined(separator: " "))
        finish(&r, l, kindBlocks: [("TySh", enc.data)])
        remember(l, r, lossy: !enc.notes.isEmpty)
    }

    // MARK: Smart objects

    func smart(_ l: Layer, _ so: SmartObjectContent) {
        var r = PSDWriteRecord(name: l.name)
        let px = rendered(l)
        setPixels(&r, px)
        let enc = PSDExportSmart.encode(l, so, ctx: self, rendered: px)
        for n in enc.notes { note(l, "Smart object", n.0, n.1) }
        finish(&r, l, kindBlocks: [], trailing: enc.blocks)
        remember(l, r, lossy: enc.lossy)
    }

    // MARK: Shared attributes

    func luni(_ name: String) -> Data {
        var w = BinaryWriter(); w.unicode(name)
        return w.data
    }

    /// Fills in name, blending, masks and the attribute blocks shared by every kind, then appends the record.
    /// `ownVectorMask`: the record already carries its path (shape layers), the layer's vector mask is not written.
    func finish(_ r: inout PSDWriteRecord, _ l: Layer, kindBlocks: [(String, Data)], trailing: [(String, Data)] = [],
                group: Bool = false, adjustment: Bool = false, ownVectorMask: Bool = false) {
        r.layerID = takeID()
        let mode = l.blendMode
        r.blendKey = group ? (mode == .passThrough ? "norm" : mode.psdKey) : (mode == .passThrough ? BlendMode.normal.psdKey : mode.psdKey)
        r.opacity = PSDExport.byte(l.opacity)
        r.clipping = l.isClipped ? 1 : 0
        if !l.isVisible { r.flags |= 0x02 }
        if l.locks.transparency { r.flags |= 0x01 }
        r.blendRanges = PSDExportContext.blendRanges(l.blendIf)
        r.linkID = l.linkID

        var vector: [(String, Data)] = []
        if !ownVectorMask, let vm = l.vectorMask, !vm.isEmpty {
            vector.append(("vmsk", PSDExportVector.vectorMaskBlock(vm, width: st.width, height: st.height, disabled: !l.vectorMaskEnabled)))
            r.vectorMask = renderVectorMask(vm, disabled: !l.vectorMaskEnabled)
        }
        r.userMask = userMask(l)
        // Photoshop gives every adjustment layer a mask: an empty white one when the user drew none.
        if adjustment, r.userMask == nil, r.vectorMask == nil { r.userMask = PSDWriteMask(rect: .zero, plane: [], defaultColor: 255) }

        // Photoshop's order: content blocks, style, name and id (a group's section marker follows its id)
        var blocks = (group ? [] : kindBlocks) + vector
        if PSDLayerStyle.shouldEncode(l.effects) { blocks.append(("lfx2", PSDLayerStyle.encode(l.effects, globalLight: st.globalLight))) }
        blocks.append(("luni", luni(l.name)))
        blocks.append(("lyid", PSDExport.u32(r.layerID)))
        if group { blocks += kindBlocks }
        blocks.append(("clbl", PSDExport.flag(l.blendClippedAsGroup)))
        blocks.append(("infx", PSDExport.flag(l.blendInteriorEffectsAsGroup)))
        blocks.append(("knko", Data([l.knockout == .deep ? 2 : (l.knockout == .shallow ? 1 : 0), 0, 0, 0])))
        var locks: UInt32 = 0
        if l.locks.transparency { locks |= 1 }
        if l.locks.pixels { locks |= 2 }
        if l.locks.position { locks |= 4 }
        if l.locks.all { locks |= 0x8000_0000 }
        blocks.append(("lspf", PSDExport.u32(locks)))
        var lclr = BinaryWriter(); lclr.u16(PSDExportContext.labelIndex(l.colorLabel)); lclr.u16(0); lclr.u32(0)
        blocks.append(("lclr", lclr.data))
        if !group, l.fillOpacity < 0.999 { blocks.append(("iOpa", Data([PSDExport.byte(l.fillOpacity), 0, 0, 0]))) }
        if l.layerMaskHidesEffects { blocks.append(("lmgm", PSDExport.flag(true))) }
        if l.vectorMaskHidesEffects { blocks.append(("vmgm", PSDExport.flag(true))) }
        if !(l.channelR && l.channelG && l.channelB) {
            var w = BinaryWriter()
            if !l.channelR { w.u32(0) }
            if !l.channelG { w.u32(1) }
            if !l.channelB { w.u32(2) }
            blocks.append(("brst", w.data))
        }
        r.blocks = blocks + trailing
        records.append(r)
        if !l.blendIf.isDefault { note(l, "Blend If", .editable, l.blendIf.channel.rawValue) }
    }

    static func labelIndex(_ c: LayerColorLabel) -> UInt16 {
        switch c {
        case .none: return 0
        case .red: return 1
        case .orange: return 2
        case .yellow: return 3
        case .green: return 4
        case .blue: return 5
        case .violet: return 6
        case .gray: return 7
        }
    }

    /// Blending ranges: composite gray, then red, green, blue (and one spare entry, as Photoshop writes for RGB).
    /// Each entry: this layer (black low, black high, white low, white high), then the underlying layer.
    static func blendRanges(_ b: BlendIf) -> Data {
        var w = BinaryWriter()
        let index: Int
        switch b.channel {
        case .gray: index = 0
        case .red: index = 1
        case .green: index = 2
        case .blue: index = 3
        }
        func v(_ x: Double) -> UInt8 { UInt8(clamp(PSDExport.fin(x), 0, 255).rounded()) }
        for i in 0..<5 {
            if i == index, !b.isDefault, b.thisLow.count == 2, b.thisHigh.count == 2, b.underLow.count == 2, b.underHigh.count == 2 {
                w.bytes([v(b.thisLow[0]), v(max(b.thisLow[0], b.thisLow[1])), v(b.thisHigh[0]), v(max(b.thisHigh[0], b.thisHigh[1]))])
                w.bytes([v(b.underLow[0]), v(max(b.underLow[0], b.underLow[1])), v(b.underHigh[0]), v(max(b.underHigh[0], b.underHigh[1]))])
            } else {
                w.bytes([0, 0, 255, 255, 0, 0, 255, 255])
            }
        }
        return w.data
    }

    /// The layer's pixel mask as stored. Feather and density travel as mask parameters; a feather that is not
    /// centred (Lumen only) is baked into the pixels.
    func userMask(_ l: Layer) -> PSDWriteMask? {
        guard let m = l.mask else { return nil }
        let feather = PSDExport.fin(m.feather)
        let density = clamp(PSDExport.fin(m.density, 1), 0, 1)
        if feather > 0, let dir = m.featherDirection, dir != .centered {
            var tmp = l
            tmp.mask?.isEnabled = true
            tmp.vectorMask = nil
            guard let img = Compositor.shared.maskImage(tmp, space: sp, raster: true, vector: false) else { return nil }
            let rect = st.canvasRect.union(m.frame)
            let buf = RenderEngine.renderBuffer(img, docRect: rect, space: sp, format: .gray)
            let outside = UInt8(clamping: Int((255 - density * Double(255 - Int(m.outsideValue))).rounded()))
            note(l, "Layer mask", .approximated, "The mask feather runs \(dir.rawValue); Photoshop only feathers centred, so it is baked into the mask.")
            return PSDWriteMask(rect: rect, plane: PSDExport.grayPlane(buf), defaultColor: outside >= 128 ? 255 : 0, disabled: !m.isEnabled, unlinked: !m.isLinked)
        }
        var out = PSDWriteMask(rect: m.frame, plane: PSDExport.grayPlane(m.buffer), defaultColor: m.outsideValue >= 128 ? 255 : 0,
                               disabled: !m.isEnabled, unlinked: !m.isLinked)
        if m.outsideValue != 0 && m.outsideValue != 255 {
            // Photoshop's area outside the mask is black or white: extend the stored mask over the canvas instead
            let rect = st.canvasRect.union(m.frame)
            var plane = [UInt8](repeating: m.outsideValue, count: rect.width * rect.height)
            let src = out.plane
            for y in 0..<m.frame.height { for x in 0..<m.frame.width {
                plane[(m.frame.y - rect.y + y) * rect.width + (m.frame.x - rect.x + x)] = src[y * m.frame.width + x]
            } }
            out.rect = rect; out.plane = plane
        }
        if density < 0.999 { out.density = PSDExport.byte(density) }
        if feather > 0 { out.feather = min(feather, 1000) }
        return out
    }

    /// Photoshop's rendering of a vector mask (white inside), cropped to the path.
    func renderVectorMask(_ p: VectorPath, disabled: Bool) -> PSDWriteMask? {
        let img = ShapeRenderer.renderMask(p, space: sp)
        let buf = RenderEngine.renderBuffer(img, docRect: st.canvasRect, space: sp, format: .gray)
        let plane = PSDExport.grayPlane(buf)
        guard let b = PSDExport.bounds(plane, width: buf.width, height: buf.height, background: 0) else {
            return PSDWriteMask(rect: .zero, plane: [], defaultColor: 0, disabled: disabled)
        }
        return PSDWriteMask(rect: b, plane: PSDExport.crop(plane, width: buf.width, to: b), defaultColor: 0, disabled: disabled)
    }

    /// Keeps the exact Lumen layer when Photoshop's representation loses something (see PSDExportLumen).
    func remember(_ l: Layer, _ r: PSDWriteRecord, lossy: Bool) {
        guard PSDExport.writeLumenData else { return }
        if l.isRaster || l.isGroup { return }
        // recipes refer to other layers by id and component instances to masters the PSD does not carry: neither can
        // be restored faithfully, so they stay pixels / plain smart objects
        if l.fill?.recipe != nil || l.smart?.component != nil { return }
        let always = l.isText || l.isShape || l.isFill || l.isAdjustment
        guard always || lossy else { return }
        lumen.append(PSDExportLumen.entry(l, records.last ?? r))
    }

    // MARK: File

    func file() throws -> Data {
        let flattened = Compositor.shared.flatten(st)
        let merged = flattened.map { PixelBuffer(cgImage: $0) }
        let transparent = merged.map(hasTransparency) ?? false
        // 16-bit documents: the composite at 16 bits per channel (8-bit layers are widened exactly, v × 257)
        let merged16 = depth == 16 && merged != nil ? PSDExport.planes16(Compositor.shared.composite(st), docRect: st.canvasRect, space: sp) : nil
        let alphas = st.alphaChannels.filter { $0.buffer.width == st.width && $0.buffer.height == st.height }.prefix(50)
        let channels = 3 + (transparent ? 1 : 0) + alphas.count

        var w = BinaryWriter()
        w.ascii("8BPS"); w.u16(large ? 2 : 1); w.bytes([0, 0, 0, 0, 0, 0])
        w.u16(UInt16(channels)); w.u32(UInt32(st.height)); w.u32(UInt32(st.width)); w.u16(UInt16(depth)); w.u16(3)
        w.u32(0)   // colour mode data

        let res = resources(alphaNames: alphas.map(\.name))
        w.u32(UInt32(res.count)); w.raw(res)

        // Layer and mask information
        let li = layerInfo(negativeCount: transparent)
        var lmi = BinaryWriter()
        if depth == 16 { lmi.len(0, large: large) } else { lmi.len(li.count, large: large); lmi.raw(li) }
        lmi.u32(0)   // global layer mask info
        var globals: [(String, Data)] = []
        // Photoshop's order: merged transparency marker, layers, text engine data, patterns, linked files
        if depth == 16 && transparent { globals.append(("Mt16", Data())) }
        if depth == 16 { globals.append(("Lr16", li)) }
        if PSDExport.writeTextEngineData, !texts.isEmpty, let txt2 = PSDExportTxt2.block(texts) { globals.append(("Txt2", txt2)) }
        let patt = PSDExportVector.patternsBlock(patternIDs)
        if !patt.isEmpty { globals.append(("Patt", patt)) }
        let embedded = links.filter { $0.externalPath == nil }, external = links.filter { $0.externalPath != nil }
        if !embedded.isEmpty { globals.append(("lnk2", PSDExportSmart.linksBlock(embedded))) }
        if !external.isEmpty { globals.append(("lnkE", PSDExportSmart.linksBlock(external))) }
        for (key, payload) in globals {
            lmi.ascii("8BIM"); lmi.ascii(key); lmi.len(payload.count, large: large && PSDExport.longKeys.contains(key)); lmi.raw(payload)
            for _ in 0..<((4 - payload.count % 4) % 4) { lmi.u8(0) }
        }
        w.len(lmi.data.count, large: large); w.raw(lmi.data)

        // Merged image: colour matted on white, then transparency and saved alpha channels
        let W = st.width, H = st.height
        var planes: [[UInt8]] = []
        var wide: [[UInt16]] = []
        if let m = merged16, m.count == 4, m[0].count == W * H {
            var r = m[0], g = m[1], b = m[2]
            for i in 0..<(W * H) where m[3][i] < 65535 {
                let a = UInt32(m[3][i])
                r[i] = UInt16((UInt32(r[i]) * a + 65535 * (65535 - a) + 32767) / 65535)
                g[i] = UInt16((UInt32(g[i]) * a + 65535 * (65535 - a) + 32767) / 65535)
                b[i] = UInt16((UInt32(b[i]) * a + 65535 * (65535 - a) + 32767) / 65535)
            }
            wide = [r, g, b]
            if transparent { wide.append(m[3]) }
        }
        if let m = merged, m.width == W, m.height == H {
            let pl = PSDExport.planes(m)
            var r = pl[0], g = pl[1], b = pl[2]
            for i in 0..<(W * H) where pl[3][i] < 255 {
                let a = Int(pl[3][i])
                r[i] = UInt8((Int(r[i]) * a + 255 * (255 - a) + 127) / 255)
                g[i] = UInt8((Int(g[i]) * a + 255 * (255 - a) + 127) / 255)
                b[i] = UInt8((Int(b[i]) * a + 255 * (255 - a) + 127) / 255)
            }
            planes = [r, g, b]
            if transparent { planes.append(pl[3]) }
        } else {
            let white = [UInt8](repeating: 255, count: W * H)
            planes = [white, white, white]
            if transparent { planes.append([UInt8](repeating: 255, count: W * H)) }
        }
        for a in alphas { planes.append(PSDExport.grayPlane(a.buffer)) }
        // 16-bit: uncompressed, like Photoshop. The system's PSD decoder (Finder, Quick Look, Preview, the Open panel)
        // reads RLE only at 8 bits and shows a 16-bit RLE composite as blank.
        let raw = depth == 16
        w.u16(raw ? 0 : 1)
        var counts = BinaryWriter(), body = BinaryWriter()
        let rb = W * (depth / 8)
        var row = [UInt8](repeating: 0, count: rb)
        for (k, p) in planes.enumerated() {
            let w16: [UInt16]? = k < wide.count ? wide[k] : nil
            p.withUnsafeBufferPointer { ptr in
                for y in 0..<H {
                    if depth == 16, let w16 {
                        for x in 0..<W { let v = w16[y * W + x]; row[x * 2] = UInt8(v >> 8); row[x * 2 + 1] = UInt8(v & 0xff) }
                    } else if depth == 16 {
                        for x in 0..<W { row[x * 2] = ptr[y * W + x]; row[x * 2 + 1] = ptr[y * W + x] }
                    } else {
                        for x in 0..<W { row[x] = ptr[y * W + x] }
                    }
                    if raw { body.bytes(row); continue }
                    let e = row.withUnsafeBufferPointer { PackBits.encode($0) }
                    if large { counts.u32(UInt32(e.count)) } else { counts.u16(UInt16(e.count)) }
                    body.bytes(e)
                }
            }
        }
        w.raw(counts.data); w.raw(body.data)
        return w.data
    }

    func hasTransparency(_ b: PixelBuffer) -> Bool {
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<b.height { let row = p + y * b.bytesPerRow; for x in 0..<b.width where row[x * 4 + 3] < 255 { return true } }
        return false
    }

    func layerInfo(negativeCount: Bool) -> Data {
        var li = BinaryWriter()
        li.i16(Int16(clamping: negativeCount ? -records.count : records.count))
        var channelData = BinaryWriter()
        for r in records {
            li.i32(Int32(r.rect.y)); li.i32(Int32(r.rect.x)); li.i32(Int32(r.rect.maxY)); li.i32(Int32(r.rect.maxX))
            var chans: [(Int16, Data)] = []
            let hasPixels = !r.rect.isEmpty && r.planes.count == 3
            let wide = hasPixels && depth == 16 ? r.wide : nil
            for (id, plane) in [(Int16(-1), r.alpha)] + (hasPixels ? r.planes : [[], [], []]).enumerated().map({ (Int16($0.offset), $0.element) }) {
                let w16 = wide.map { $0[id < 0 ? 3 : Int(id)] }
                chans.append((id, hasPixels ? PSDExport.channel(plane, width: r.rect.width, height: r.rect.height, depth: depth, large: large, wide: w16)
                                            : PSDExport.channel([], width: 0, height: 0, depth: depth, large: large)))
            }
            let primary = r.vectorMask ?? r.userMask
            if let m = primary { chans.append((-2, PSDExport.channel(m.plane, width: m.rect.width, height: m.rect.height, depth: depth, large: large))) }
            if r.vectorMask != nil, let u = r.userMask { chans.append((-3, PSDExport.channel(u.plane, width: u.rect.width, height: u.rect.height, depth: depth, large: large))) }
            li.u16(UInt16(chans.count))
            for (id, e) in chans { li.i16(id); li.len(e.count, large: large) }
            li.ascii("8BIM"); li.ascii(r.blendKey)
            li.u8(r.opacity); li.u8(r.clipping); li.u8(r.flags); li.u8(0)
            var extra = BinaryWriter()
            let mask = PSDExportContext.maskData(user: r.userMask, vector: r.vectorMask)
            extra.u32(UInt32(mask.count)); extra.raw(mask)
            extra.u32(UInt32(r.blendRanges.count)); extra.raw(r.blendRanges)
            extra.pascal(PSDExportContext.pascalName(r.name), pad: 4)
            for (key, payload) in r.blocks {
                var body = payload
                while body.count % 4 != 0 { body.append(0) }
                extra.ascii("8BIM"); extra.ascii(key); extra.len(body.count, large: large && PSDExport.longKeys.contains(key)); extra.raw(body)
            }
            li.u32(UInt32(extra.data.count)); li.raw(extra.data)
            for (_, e) in chans { channelData.raw(e) }
        }
        li.raw(channelData.data)
        while li.data.count % 4 != 0 { li.u8(0) }
        return li.data
    }

    /// The legacy (Pascal) name: Mac Roman-safe ASCII, at most 255 bytes without splitting a character.
    static func pascalName(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            let c: Character = ch.isASCII && ch.value >= 32 ? Character(ch) : "_"
            if out.utf8.count + 1 > 255 { break }
            out.append(c)
        }
        return out
    }

    /// Mask record of the layer: the user mask alone (20 bytes, or with parameters), or the rendered vector mask
    /// followed by the "real" user mask.
    static func maskData(user: PSDWriteMask?, vector: PSDWriteMask?) -> Data {
        guard let primary = vector ?? user else { return Data() }
        var w = BinaryWriter()
        func rect(_ r: IRect) { w.i32(Int32(r.y)); w.i32(Int32(r.x)); w.i32(Int32(r.maxY)); w.i32(Int32(r.maxX)) }
        func flags(_ m: PSDWriteMask) -> UInt8 { (m.unlinked ? 0x01 : 0) | (m.disabled ? 0x02 : 0) }
        let params = user.map { $0.density != nil || $0.feather != nil } ?? false
        rect(primary.rect)
        w.u8(primary.defaultColor)
        var f = flags(primary)
        if vector != nil { f |= 0x08 }
        if params { f |= 0x10 }
        w.u8(f)
        if params, let u = user {
            w.u8((u.density != nil ? 1 : 0) | (u.feather != nil ? 2 : 0))
            if let d = u.density { w.u8(d) }
            if let fe = u.feather { w.u64(fe.bitPattern) }
        }
        if vector != nil, let u = user {
            w.u8(flags(u)); w.u8(u.defaultColor); rect(u.rect)
        } else if params {
            // the "real" fields repeat the user mask so the record cannot be mistaken for the 20-byte form
            w.u8(flags(primary)); w.u8(primary.defaultColor); rect(primary.rect)
        } else {
            w.u16(0)
        }
        return w.data
    }

    // MARK: Image resources

    func resources(alphaNames: [String]) -> Data {
        var res = BinaryWriter()
        func add(_ id: UInt16, _ body: Data, name: String = "") {
            res.ascii("8BIM"); res.u16(id); res.pascal(name, pad: 2); res.u32(UInt32(body.count)); res.raw(body)
            if body.count % 2 == 1 { res.u8(0) }
        }
        // Resolution (16.16 fixed, pixels per inch)
        var r = BinaryWriter()
        let fixedRes = UInt32(clamp(PSDExport.fin(st.resolution, 72), 1, 30000) * 65536)
        r.u32(fixedRes); r.u16(1); r.u16(1); r.u32(fixedRes); r.u16(1); r.u16(1)
        add(1005, r.data)
        // Alpha channel names and display info
        if !alphaNames.isEmpty {
            var p = BinaryWriter()
            for n in alphaNames { p.pascal(PSDExportContext.pascalName(n), pad: 1) }
            add(1006, p.data)
            var u = BinaryWriter()
            for n in alphaNames { u.unicode(n + "\u{0}") }
            add(1045, u.data)
            var d = BinaryWriter()
            d.u32(1)
            for _ in alphaNames { d.u16(0); d.u16(65535); d.u16(0); d.u16(0); d.u16(0); d.u16(50); d.u8(1) }
            add(1077, d.data)
        }
        // Global light: angle (1037), altitude (1049)
        add(1037, PSDExport.u32(UInt32(bitPattern: Int32(PSDExport.fin(st.globalLight.angle, 120).rounded()))))
        add(1049, PSDExport.u32(UInt32(bitPattern: Int32(PSDExport.fin(st.globalLight.altitude, 30).rounded()))))
        // Guides: version, grid cycle, count, then position (1/32 px) and direction (0 vertical, 1 horizontal)
        var g = BinaryWriter()
        let guides = st.guides.filter { $0.position.isFinite && abs($0.position) < 30_000_000 }
        g.u32(1); g.u32(576); g.u32(576); g.u32(UInt32(guides.count))
        for gd in guides { g.i32(Int32((gd.position * 32).rounded())); g.u8(gd.isVertical ? 0 : 1) }
        add(1032, g.data)
        // Linked layers (1026): one group number per layer record, 0 = not linked
        var groups: [UUID: UInt16] = [:]
        var link = BinaryWriter()
        for r in records { link.u16(r.linkID.map { id in groups[id] ?? { let n = UInt16(groups.count + 1); groups[id] = n; return n }() } ?? 0) }
        if !groups.isEmpty { add(1026, link.data) }
        // ICC profile of the pixel values
        // profileName is a CGColorSpace name, or a ColorProfiles entry name (documents opened from files)
        let cs = CGColorSpace(name: st.profileName as CFString) ?? ColorProfiles.space(named: st.profileName)
        if let icc = cs.copyICCData() as Data? {
            add(1039, icc)
        }
        // Paths: the work path (1025) and saved paths (2000…)
        var pathID: UInt16 = 2000
        for p in st.paths where !p.path.isEmpty && pathID < 2998 {
            let rec = PSDExportVector.pathRecords(p.path, width: st.width, height: st.height)
            if p.name == "Work Path" { add(1025, rec) } else { add(pathID, rec, name: PSDExportContext.pascalName(p.name)); pathID += 1 }
        }
        if PSDExport.writeLumenData, !lumen.isEmpty, let d = PSDExportLumen.resource(lumen) {
            add(PSDExportLumen.resourceID, d, name: PSDExportLumen.resourceName)
        }
        return res.data
    }
}

extension ShapeGeometry {
    /// Rectangles and ellipses: Photoshop keeps these as live shapes.
    var isPhotoshopPrimitive: Bool {
        switch self {
        case .rectangle, .ellipse, .path: return true
        default: return false
        }
    }
    var isLivePrimitive: Bool {
        switch self {
        case .rectangle, .ellipse: return true
        default: return false
        }
    }
}
