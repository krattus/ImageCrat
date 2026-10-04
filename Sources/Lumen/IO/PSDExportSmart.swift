import Foundation
import CoreGraphics
import ImageIO
import ImageCratCore

// Smart objects for export (the inverse of PSDSmart): the placement ('SoLd' version 4 and the older 'PlLd'), and the
// file it shows in the global 'lnk2' block — a PNG of an image source or a PSB of a document source (written by this
// exporter, so nested smart objects stay live). A linked smart object is placed with 'SoLE' and refers to its file
// through a 'liFE' record in the global 'lnkE' block (Photoshop keeps external links out of 'lnk2', which holds
// embedded files only): link type, file name, Mac type / creator, the file reference descriptor (full path, original
// path, path relative to the document), the file's date and size, and no embedded copy.

enum PSDExportSmart {
    struct Link {
        var id: String
        var name: String
        var type: String
        var creator: String
        var data: Data
        var externalPath: String? = nil
        /// External links: the file's modification date and size when it was written.
        var fileDate: Date? = nil
        var fileSize: UInt64 = 0
    }

    struct Encoded {
        var blocks: [(String, Data)]
        var notes: [(PSDExportNote.Status, String)]
        var lossy: Bool
    }

    private typealias V = PSDDescriptorValue
    private static func fin(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// File types Photoshop opens as smart object contents, with their Mac file type codes.
    static let fileTypes: [String: String] = ["png": "png ", "jpg": "JPEG", "jpeg": "JPEG", "tif": "TIFF", "tiff": "TIFF", "psd": "8BPS", "psb": "8BPB",
                                              "gif": "GIFf", "bmp": "BMP ", "pdf": "PDF ", "ai": "PDF "]

    static func encode(_ l: Layer, _ so: SmartObjectContent, ctx: PSDExportContext, rendered: (PixelBuffer, IPoint)?) -> Encoded {
        var notes: [(PSDExportNote.Status, String)] = []
        var lossy = so.component != nil
        let filters = so.filtersEnabled ? so.filters.filter(\.enabled) : []
        var baked: [String] = []
        if !filters.isEmpty { baked.append("smart filter\(filters.count == 1 ? "" : "s") \(filters.map { "“\($0.kind.displayName)”" }.joined(separator: ", "))") }
        if so.warp != nil { baked.append("the mesh warp") }
        if so.stackMode != nil { baked.append("the stack mode") }

        var source = so.source
        var quad = so.quad
        if !baked.isEmpty {
            // The contents become what the layer shows, placed 1:1 where it shows: same look, still a smart object.
            if let (buf, o) = rendered {
                source = .image(buf)
                quad = Quad(rect: CGRect(x: o.x, y: o.y, width: buf.width, height: buf.height))
            } else {
                source = .image(PixelBuffer(width: 1, height: 1))
                quad = Quad(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            notes.append((.baked, "Photoshop cannot reproduce \(baked.joined(separator: " and ")); \(baked.count == 1 ? "it is" : "they are") baked into the smart object's contents."))
            lossy = true
        }
        if !quad.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1e7 && abs($0.y) < 1e7 }) {
            let s = source.size
            quad = Quad(rect: CGRect(origin: .zero, size: CGSize(width: max(1, s.width), height: max(1, s.height))))
        }

        let uid = UUID().uuidString.lowercased()
        let base = baseName(so.sourceName.isEmpty ? l.name : so.sourceName)
        var link: Link? = nil
        var external = false
        if baked.isEmpty, let url = so.linkedURL {
            let ext = url.pathExtension.lowercased()
            let attrs = url.isFileURL ? try? FileManager.default.attributesOfItem(atPath: url.path) : nil
            if PSDExport.writeExternalLinks, let attrs, (attrs[.type] as? FileAttributeType) != .typeDirectory {
                link = Link(id: uid, name: url.lastPathComponent, type: fileTypes[ext] ?? "    ", creator: "\0\0\0\0", data: Data(), externalPath: url.standardizedFileURL.path,
                            fileDate: attrs[.modificationDate] as? Date, fileSize: (attrs[.size] as? NSNumber)?.uint64Value ?? 0)
                external = true
                notes.append((.editable, "linked to “\(url.lastPathComponent)”"))
            } else if let type = fileTypes[ext], let d = try? Data(contentsOf: url, options: .mappedIfSafe), !d.isEmpty, d.count < 2_000_000_000 {
                link = Link(id: uid, name: url.lastPathComponent, type: type, creator: "\0\0\0\0", data: d)
                notes.append((.approximated, "The linked file “\(url.lastPathComponent)” is embedded (Layer ▸ Smart Objects ▸ Convert to Linked restores the link in Photoshop)."))
            }
            lossy = true
        }
        var size = source.size
        var resolution = 72.0
        if link == nil {
            switch source {
            case .image(let b):
                link = Link(id: uid, name: base + ".png", type: "png ", creator: "\0\0\0\0", data: b.pngData() ?? Data())
            case .document(let doc):
                resolution = doc.resolution
                if ctx.nesting + 1 < PSDExport.maxNesting, let (d, nested) = try? PSDExport.encode(doc, large: true, nesting: ctx.nesting + 1) {
                    link = Link(id: uid, name: base + ".psb", type: "8BPB", creator: "8BIM", data: d)
                    for n in nested { ctx.notes.append(PSDExportNote(layer: "\(l.name) ▸ \(n.layer)", feature: n.feature, status: n.status, detail: n.detail)) }
                } else {
                    let img = Compositor.shared.flatten(doc).map { PixelBuffer(cgImage: $0) } ?? PixelBuffer(width: 1, height: 1)
                    link = Link(id: uid, name: base + ".png", type: "png ", creator: "\0\0\0\0", data: img.pngData() ?? Data())
                    size = CGSize(width: img.width, height: img.height)
                    notes.append((.baked, "Smart objects nested this deep are embedded as a flat picture."))
                    lossy = true
                }
            }
        } else if case .image(let b) = source, let d = link?.data, let img = CGImageSourceCreateWithData(d as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(img, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w != b.width || h != b.height {
            size = CGSize(width: w, height: h)
        }
        guard let lk = link else { return Encoded(blocks: [], notes: notes, lossy: true) }
        ctx.links.append(lk)
        if notes.isEmpty || !notes.contains(where: { $0.0 != .editable }) {
            notes.append((.editable, "embedded \(lk.name) (\(Int(size.width)) × \(Int(size.height)) px)" + (quad.isAffine ? "" : ", perspective")))
        }

        let corners = [quad.tl, quad.tr, quad.br, quad.bl].flatMap { [fin(Double($0.x)), fin(Double($0.y))] }
        let w = max(1, fin(Double(size.width))), h = max(1, fin(Double(size.height)))
        let warp = PSDDescriptor(classID: "warp", [
            ("warpStyle", .enumerated(type: "warpStyle", value: "warpNone")), ("warpValue", .double(0)), ("warpPerspective", .double(0)),
            ("warpPerspectiveOther", .double(0)), ("warpRotate", .enumerated(type: "Ornt", value: "Hrzn")),
            ("bounds", .object(PSDDescriptor(classID: "Rctn", [("Top ", .unitFloat(unit: "#Pxl", value: 0)), ("Left", .unitFloat(unit: "#Pxl", value: 0)),
                                                              ("Btom", .unitFloat(unit: "#Pxl", value: h)), ("Rght", .unitFloat(unit: "#Pxl", value: w))]))),
            ("uOrder", .integer(4)), ("vOrder", .integer(4)),
        ])
        let frame = PSDDescriptor(classID: "null", [("numerator", .integer(0)), ("denominator", .integer(600))])
        let sold = PSDDescriptor(classID: "null", [
            ("Idnt", .string(uid)), ("placed", .string(UUID().uuidString.lowercased())), ("PgNm", .integer(1)), ("totalPages", .integer(1)),
            ("frameStep", .object(frame)), ("duration", .object(frame)), ("frameCount", .integer(1)),
            ("Annt", .integer(16)), ("Type", .integer(2)),
            ("Trnf", .list(corners.map { .double($0) })), ("nonAffineTransform", .list(corners.map { .double($0) })),
            ("warp", .object(warp)),
            ("Sz  ", .object(PSDDescriptor(classID: "Pnt ", [("Wdth", .double(w)), ("Hght", .double(h))]))),
            ("Rslt", .unitFloat(unit: "#Rsl", value: clamp(resolution.isFinite ? resolution : 72, 1, 30000))),
            ("comp", .integer(-1)),
        ])
        var s = BinaryWriter()
        s.ascii("soLD"); s.u32(4)
        s.raw(sold.serializedVersioned())
        var p = BinaryWriter()
        p.ascii("plcL"); p.u32(3); p.pascal(uid, pad: 1)
        p.i32(1); p.i32(1); p.i32(16); p.i32(2)
        for v in corners { p.u64(v.bitPattern) }
        p.u32(0); p.u32(16)
        var dw = PSDDescriptorWriter(); dw.descriptor(warp)
        p.raw(dw.data)
        return Encoded(blocks: [("PlLd", p.data), (external ? "SoLE" : "SoLd", s.data)], notes: notes, lossy: lossy)
    }

    /// The file reference of a linked smart object: name, file URL, POSIX path and the path relative to the folder of
    /// the document (Photoshop looks there when the full path no longer exists, e.g. after the folder was moved).
    static func externalFileLink(_ name: String, path: String, relativeTo folder: URL?) -> PSDDescriptor {
        let url = URL(fileURLWithPath: path)
        return PSDDescriptor(classID: "ExternalFileLink", [
            ("descVersion", .integer(2)), ("Nm  ", .string(name)), ("fullPath", .string(url.absoluteString)),
            ("originalPath", .string(url.path)), ("relPath", .string(relativePath(url, from: folder))),
        ])
    }

    /// `url` relative to `folder` ("linked.png", "../images/linked.png"); the file name when there is no folder.
    static func relativePath(_ url: URL, from folder: URL?) -> String {
        guard let folder else { return url.lastPathComponent }
        let a = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents, b = url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().pathComponents
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        guard i > 0 else { return url.lastPathComponent }
        let up = Array(repeating: "..", count: a.count - i)
        return (up + b[i...] + [url.lastPathComponent]).joined(separator: "/")
    }

    static func baseName(_ s: String) -> String {
        let n = (s as NSString).deletingPathExtension
        let clean = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean.isEmpty ? "Smart Object" : String(clean.prefix(120))
    }

    /// 'lnk2' (embedded files) / 'lnkE' (links to external files): per file a 64-bit length, then the record (version 5
    /// for embedded files; version 7 for external links, the last layout before Photoshop 2026's content-ID trailer),
    /// padded to 4 bytes.
    static func linksBlock(_ links: [Link]) -> Data {
        var out = BinaryWriter()
        for lk in links {
            var e = BinaryWriter()
            let external = lk.externalPath != nil
            e.ascii(external ? "liFE" : "liFD"); e.u32(external ? 7 : 5)
            e.pascal(lk.id, pad: 1)
            e.unicode(lk.name + "\u{0}")
            e.bytes(Array((lk.type + "    ").unicodeScalars.prefix(4).map { UInt8(truncatingIfNeeded: $0.value) }))
            e.bytes(Array((lk.creator + "\0\0\0\0").unicodeScalars.prefix(4).map { UInt8(truncatingIfNeeded: $0.value) }))
            e.u64(UInt64(lk.data.count))
            e.u8(1)
            let open = PSDDescriptor(classID: "null", [("compInfo", .object(PSDDescriptor(classID: "null", [("compID", .integer(-1)), ("originalCompID", .integer(-1))])))])
            e.raw(open.serializedVersioned())
            if let path = lk.externalPath {
                let recorded = PSDExport.recordedFolder.map { $0.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path } ?? path
                e.raw(externalFileLink(lk.name, path: recorded, relativeTo: PSDExport.recordedFolder ?? PSDExport.outputFolder).serializedVersioned())
                // the file's modification date (UTC; month 1–12, seconds with their fraction) and size: Photoshop
                // compares them with the file on disk to flag a modified link
                let date = lk.fileDate ?? Date(timeIntervalSince1970: 0)
                let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
                let sec = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9
                e.u32(UInt32(c.year ?? 1970)); e.u8(UInt8(c.month ?? 1)); e.u8(UInt8(c.day ?? 1)); e.u8(UInt8(c.hour ?? 0)); e.u8(UInt8(c.minute ?? 0))
                e.u64(sec.bitPattern)
                e.u64(lk.fileSize)
                // child document id (empty), asset modification time, asset lock state
                e.unicode("\u{0}"); e.u64(Double(0).bitPattern); e.u8(0)
            } else {
                e.raw(lk.data)
                e.unicode("\u{0}")
            }
            out.u64(UInt64(e.data.count)); out.raw(e.data)
            while out.data.count % 4 != 0 { out.u8(0) }
        }
        return out.data
    }
}
