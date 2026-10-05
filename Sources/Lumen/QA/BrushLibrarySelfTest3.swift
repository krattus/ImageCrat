import AppKit
import ImageCratCore

/// Stands in for Procreate's archived brush object (`$top.root` of Brush.archive): keys encoded directly.
@objc(SilicaBrush) final class FakeSilicaBrush: NSObject, NSCoding {
    let values: [String: Any]
    init(_ v: [String: Any]) { values = v }
    required init?(coder: NSCoder) { values = [:] }
    func encode(with coder: NSCoder) {
        for (k, v) in values {
            switch v {
            case let d as Double: coder.encode(d, forKey: k)
            case let s as String: coder.encode(s, forKey: k)
            case let b as Bool: coder.encode(b, forKey: k)
            default: break
            }
        }
    }
}

extension BrushLibrarySelfTest {
    // MARK: - Synthetic files (built from the published layouts)

    static func be16(_ v: Int, _ d: inout Data) { d.append(UInt8(truncatingIfNeeded: v >> 8)); d.append(UInt8(truncatingIfNeeded: v)) }
    static func be32(_ v: Int, _ d: inout Data) { be16(v >> 16, &d); be16(v, &d) }

    /// w×h gray ring (255 = paint).
    static func ring(_ w: Int, _ h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let dx = (Double(x) + 0.5) / Double(w) - 0.5, dy = (Double(y) + 0.5) / Double(h) - 0.5
            let r = sqrt(dx * dx + dy * dy) * 2
            px[y * w + x] = r < 0.95 && r > 0.55 ? 255 : (r <= 0.55 ? 90 : 0)
        } }
        return px
    }

    static func grayBuffer(_ px: [UInt8], _ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h, format: .gray)
        let d = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { d[y * b.bytesPerRow + x] = px[y * w + x] } }
        b.markDirty()
        return b
    }

    static func sampleEntry(key: String, w: Int, h: Int, px: [UInt8]) -> Data {
        var b = Data()
        b.append(UInt8(key.utf8.count)); b.append(contentsOf: Array(key.utf8))
        b.append(Data(count: 264))
        be32(0, &b); be32(0, &b); be32(h, &b); be32(w, &b); be16(8, &b); b.append(0)
        b.append(contentsOf: px)
        var e = Data(); be32(b.count, &e); e.append(b)
        while e.count % 4 != 0 { e.append(0) }
        return e
    }

    static func section(_ tag: String, _ body: Data) -> Data {
        var d = Data(Array("8BIM".utf8)); d.append(contentsOf: Array(tag.utf8)); be32(body.count, &d); d.append(body); return d
    }

    /// ABR v10: a computed preset, a group "Inkers" with a sampled preset (shape dynamics, scattering, transfer, wet
    /// edges) and a nested group, plus one preset whose tip is missing (reported as skipped).
    static func syntheticABR10() -> Data {
        let k1 = "11111111-2222-3333-4444-555555555555", k2 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        var samp = Data()
        samp.append(sampleEntry(key: k1, w: 48, h: 36, px: ring(48, 36)))
        samp.append(sampleEntry(key: k2, w: 20, h: 20, px: ring(20, 20)))
        typealias V = PSDDescriptorValue
        func prc(_ v: Double) -> V { .unitFloat(unit: "#Prc", value: v) }
        func px(_ v: Double) -> V { .unitFloat(unit: "#Pxl", value: v) }
        func brVr(_ c: Int, _ j: Double, _ m: Double = 0) -> V { .object(PSDDescriptor(classID: "brVr", [("bVTy", .integer(Int32(c))), ("fStp", .integer(25)), ("jitter", prc(j)), ("Mnm ", prc(m))])) }
        func sampled(_ name: String, _ key: String, _ d: Double, extra: [(String, V)] = []) -> V {
            .object(PSDDescriptor(classID: "brushPreset", [("Nm  ", .string(name)),
                ("Brsh", .object(PSDDescriptor(classID: "sampledBrush", [("Dmtr", px(d)), ("Angl", .unitFloat(unit: "#Ang", value: 20)), ("Rndn", prc(90)), ("Spcn", prc(30)), ("sampledData", .string("$" + key))])))] + extra))
        }
        let ink = sampled("Kyle Ink", k1, 60, extra: [
            ("useTipDynamics", .bool(true)), ("szVr", brVr(2, 25)), ("minimumDiameter", prc(15)), ("angleDynamics", brVr(7, 0)),
            ("useScatter", .bool(true)), ("scatterDynamics", brVr(0, 120)), ("Cnt ", .double(2)), ("bothAxes", .bool(true)),
            ("usePaintDynamics", .bool(true)), ("opVr", brVr(2, 10, 20)), ("Wtdg", .bool(true)),
            ("dualBrush", .object(PSDDescriptor(classID: "dualBrush", [("useDualBrush", .bool(true)), ("BlnM", .enumerated(type: "BlnM", value: "Drkn")),
                ("Brsh", .object(PSDDescriptor(classID: "sampledBrush", [("Dmtr", px(18)), ("Spcn", prc(40)), ("sampledData", .string(k2))])))]))),
        ])
        let root = PSDDescriptor(classID: "null", [("Brsh", .list([
            .object(PSDDescriptor(classID: "brushPreset", [("Nm  ", .string("Hard Round 19")),
                ("Brsh", .object(PSDDescriptor(classID: "computedBrush", [("Dmtr", px(19)), ("Hrdn", prc(100)), ("Spcn", prc(25))])))])),
            .object(PSDDescriptor(classID: "brushGroup", [("Nm  ", .string("Inkers")), ("Brsh", .list([
                ink,
                .object(PSDDescriptor(classID: "brushGroup", [("Nm  ", .string("Fine")), ("Brsh", .list([sampled("Fine Liner", k2, 12)]))])),
            ]))])),
            sampled("Lost Tip", "99999999-0000-0000-0000-000000000000", 30),
        ]))])
        var d = Data()
        be16(10, &d); be16(2, &d)
        d.append(section("samp", samp))
        d.append(section("desc", root.serializedVersioned()))
        return d
    }

    /// A tool preset file: one brush tool preset (with opacity / mode / colour) and one non-brush preset.
    static func syntheticTPL() -> Data {
        let k = "12345678-1234-1234-1234-123456789abc"
        let brush = PSDDescriptor(classID: "brushPreset", [("Brsh", .object(PSDDescriptor(classID: "sampledBrush", [("Dmtr", .unitFloat(unit: "#Pxl", value: 33)), ("sampledData", .string(k))])))])
        let tool = PSDDescriptor(classID: "toolPreset", [("Nm  ", .string("Inky Pen")), ("Opct", .unitFloat(unit: "#Prc", value: 55)),
            ("Md  ", .enumerated(type: "BlnM", value: "Mltp")),
            ("Clr ", .object(PSDDescriptor(classID: "RGBC", [("Rd  ", .double(200)), ("Grn ", .double(30)), ("Bl  ", .double(30))]))), ("Brsh", .object(brush))])
        let crop = PSDDescriptor(classID: "toolPreset", [("Nm  ", .string("Crop 4x5")), ("Wdth", .double(4))])
        let root = PSDDescriptor(classID: "null", [("Prst", .list([.object(tool), .object(crop)]))])
        var d = Data(Array("8BTP".utf8)); be16(1, &d); be16(0, &d)
        d.append(section("samp", sampleEntry(key: k, w: 24, h: 24, px: ring(24, 24))))
        d.append(section("desc", root.serializedVersioned()))
        return d
    }

    static func png(_ b: PixelBuffer) -> Data { PNGCodec.encode(b) }

    static func procreateArchive(_ v: [String: Any]) -> Data {
        let a = NSKeyedArchiver(requiringSecureCoding: false)
        a.encode(FakeSilicaBrush(v), forKey: "root")
        a.finishEncoding()
        return a.encodedData
    }

    static func syntheticProcreateBrush() -> Data {
        var z = ZipWriter()
        z.add(name: "Brush.archive", data: procreateArchive(["name": "Dry Ink", "paintSize": 0.1, "plotSpacing": 0.2, "plotJitter": 0.3,
                                                              "dynamicsPressureSize": 0.8, "dynamicsJitterHue": 0.1, "grainDepth": 0.7]))
        z.add(name: "Shape.png", data: png(grayBuffer(ring(64, 64), 64, 64)))
        z.add(name: "Grain.png", data: png(grayBuffer((0..<(32 * 32)).map { UInt8(($0 * 37) & 255) }, 32, 32)))
        return z.finish()
    }

    static func syntheticProcreateSet() -> Data {
        var z = ZipWriter()
        let ids = ["7A0B1C2D-0000-4000-8000-000000000001", "7A0B1C2D-0000-4000-8000-000000000002"]
        let plist = try! PropertyListSerialization.data(fromPropertyList: ["name": "Studio Set", "brushes": Array(ids.reversed())], format: .binary, options: 0)
        z.add(name: "brushset.plist", data: plist)
        for (i, id) in ids.enumerated() {
            z.add(name: "\(id)/Brush.archive", data: procreateArchive(["name": "Studio \(i + 1)", "paintSize": 0.05 * Double(i + 1)]))
            z.add(name: "\(id)/Shape.png", data: png(ABRImporter.renderRound(diameter: 40 + i * 10, hardness: 0.5, roundness: 1, angle: 0)))
        }
        return z.finish()
    }

    static func syntheticKPP(embedded: Bool) -> Data {
        let gbr = GIMPBrushWriter.gbr(name: "Embedded", width: 30, height: 30, pixels: ring(30, 30), spacing: 15)
        let def: String
        if embedded {
            def = #"<Brush type="gbr_brush" filename="embedded.gbr" spacing="0.15" angle="0" scale="1" BrushVersion="2"/>"#
        } else {
            def = #"<Brush type="auto_brush" spacing="0.08" angle="0.5" randomness="0" density="1" BrushVersion="2"><MaskGenerator diameter="42" ratio="0.5" hfade="0.6" vfade="0.6" fade="0.5" spikes="2" type="circle" id="default"/></Brush>"#
        }
        let escaped = def.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        var xml = #"<Preset paintopid="paintbrush" name="\#(embedded ? "Krita Embedded" : "Krita Auto")"><param name="brush_definition" type="string"><![CDATA[\#(def)]]></param><param name="requiredBrushFile" type="string"><![CDATA[embedded.gbr]]></param>"#
        _ = escaped
        if embedded { xml += #"<resources><resource type="brushes" name="Embedded" filename="embedded.gbr" md5="0">\#(gbr.base64EncodedString())</resource></resources>"# }
        xml += "</Preset>"
        let icon = PixelBuffer(width: 40, height: 40)
        icon.context.setFillColor(RGBA.white.cgColor); icon.context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        icon.context.setFillColor(RGBA.black.cgColor); icon.context.fillEllipse(in: CGRect(x: 8, y: 8, width: 24, height: 24)); icon.markDirty()
        return PNGCodec.encode(icon, text: [("preset", xml)], compressText: true)
    }

    static func pictureData(_ type: NSBitmapImageRep.FileType) -> Data {
        let b = PixelBuffer(width: 90, height: 60)
        b.context.setFillColor(RGBA.white.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: 90, height: 60))
        b.context.setFillColor(RGBA(gray: 0.1).cgColor); b.context.fill(CGRect(x: 20, y: 10, width: 50, height: 40))
        b.markDirty()
        return NSBitmapImageRep(cgImage: b.makeCGImage()).representation(using: type, properties: [:]) ?? Data()
    }

    /// Every synthetic file: (file name, data).
    static func syntheticFiles() -> [(String, Data)] {
        let cells = [ABRImporter.renderRound(diameter: 32, hardness: 1, roundness: 1, angle: 0),
                     ABRImporter.renderRound(diameter: 32, hardness: 1, roundness: 0.25, angle: 0),
                     ABRImporter.renderRound(diameter: 32, hardness: 1, roundness: 0.25, angle: 90),
                     ABRImporter.renderRound(diameter: 32, hardness: 0, roundness: 1, angle: 0)].map { b -> (width: Int, height: Int, gray: [UInt8]) in
            (b.width, b.height, BrushTipImaging.tightGray(b))
        }
        return [
            ("Kyle's Inkers.abr", syntheticABR10()),
            ("Leaf v2.abr", BrushSelfTest.syntheticABR()),
            ("Tool Presets.tpl", syntheticTPL()),
            ("Ring.gbr", GIMPBrushWriter.gbr(name: "GIMP Ring", width: 50, height: 40, pixels: ring(50, 40), spacing: 20)),
            ("Pipe.gih", GIMPBrushWriter.gih(name: "GIMP Pipe", cells: cells, spacing: 60, selection: "incremental")),
            ("Dry Ink.brush", syntheticProcreateBrush()),
            ("Studio.brushset", syntheticProcreateSet()),
            ("Krita Auto.kpp", syntheticKPP(embedded: false)),
            ("Krita Embedded.kpp", syntheticKPP(embedded: true)),
            ("Rectangle.png", pictureData(.png)),
            ("Rectangle.jpg", pictureData(.jpeg)),
            ("Rectangle.tiff", pictureData(.tiff)),
        ]
    }

    // MARK: - Importers

    static func importers() {
        let l = lib("importers", defaults: false)
        var sheet: [(String, CGImage)] = []
        var urls: [URL] = []
        for (name, data) in syntheticFiles() {
            let url = tmp.appendingPathComponent(name)
            try? data.write(to: url)
            urls.append(url)
        }
        let results = l.importFiles(urls)
        func result(_ file: String) -> BrushLibrary.ImportResult? { results.first { $0.file == file } }
        func names(_ r: BrushLibrary.ImportResult?) -> [String] { (r?.added ?? []).compactMap { l.record($0)?.name } }
        for r in results {
            check(r.error == nil && !r.added.isEmpty, "import \(r.file)", r.error ?? "no brushes")
            for id in r.added {
                if let img = l.strokePreview(id, width: 160, height: 40, fg: .black) { sheet.append(("\(r.file): \(l.record(id)?.name ?? "")", img)) }
            }
        }
        // ABR v10: groups → folders, settings, skipped preset reported
        let abr = result("Kyle's Inkers.abr")
        check(names(abr) == ["Hard Round 19", "Kyle Ink", "Fine Liner"], "ABR presets in order", "\(names(abr))")
        if let top = abr?.folderID {
            check(l.index.folder(top)?.name == "Kyle's Inkers", "the ABR becomes a folder named after the file")
            let ink = abr!.added[1], fine = abr!.added[2]
            check(l.index.path(ofFolder: l.index.folderID(ofBrush: ink)!) == ["Kyle's Inkers", "Inkers"], "ABR group → folder")
            check(l.index.path(ofFolder: l.index.folderID(ofBrush: fine)!) == ["Kyle's Inkers", "Inkers", "Fine"], "nested ABR group → nested folder")
            if let p = l.record(ink)?.params {
                check(p.size == 60 && abs(p.spacing - 0.3) < 1e-6 && abs(p.roundness - 0.9) < 1e-6 && p.angle == 20, "ABR tip shape settings")
                check(p.shapeEnabled && p.sizeControl.source == .pressure && abs(p.sizeJitter - 0.25) < 1e-6 && abs(p.minDiameter - 0.15) < 1e-6
                      && p.angleControl.source == .direction, "ABR shape dynamics")
                check(p.scatterEnabled && abs(p.scatter - 1.2) < 1e-6 && p.count == 2 && p.scatterBothAxes, "ABR scattering")
                check(p.transferEnabled && p.opacityControl.source == .pressure && abs(p.minOpacity - 0.2) < 1e-6, "ABR transfer")
                check(p.wetEdges, "ABR wet edges")
                check(p.dualEnabled && p.dualMode == .darken && p.dualSize == 18 && l.tipBuffer(p.dualTipID) != nil, "ABR dual brush with its own sampled tip")
            }
            if let t = l.record(ink).flatMap({ l.tipBuffer($0.tipID) }) {
                check(t.width == 48 && t.height == 48 && gray(t, 24, 6 + 2) == ring(48, 36)[2 * 48 + 24], "ABR sampled tip pixels (48×36 centred in a square)")
                savePNG(t, "imported_tip_abr")
            }
        }
        check(abr?.skipped.contains { $0.contains("Lost Tip") } == true, "a preset whose tip is missing is reported as skipped")
        let summary = l.summary(results)
        check(summary.contains("Imported 3 brushes into “Kyle's Inkers”; 1 skipped: Lost Tip"), "summary line", summary.components(separatedBy: "\n").first ?? "")
        // v2
        check(names(result("Leaf v2.abr")) == ["Synthetic Leaf"], "ABR v2 sampled brush name")
        // TPL
        let tpl = result("Tool Presets.tpl")
        check(names(tpl) == ["Inky Pen"], "TPL: the brush tool preset (non-brush presets ignored)", "\(names(tpl))")
        if let id = tpl?.added.first, let r = l.record(id) {
            check(r.includesToolSettings && abs(r.params.opacity - 0.55) < 1e-6 && r.params.blendMode == "multiply" && r.color != nil, "TPL tool settings and colour")
        }
        // GIMP
        if let id = result("Ring.gbr")?.added.first, let r = l.record(id), let t = l.tipBuffer(r.tipID) {
            check(r.name == "GIMP Ring" && abs(r.params.spacing - 0.2) < 1e-6 && t.width == 50, "GBR: name, spacing, tip", "\(r.name) \(r.params.spacing) \(t.width)")
            check(gray(t, 25, 5 + 20) == ring(50, 40)[20 * 50 + 25], "GBR tip pixels (255 = paint)")
            savePNG(t, "imported_tip_gbr")
        }
        if let id = result("Pipe.gih")?.added.first, let r = l.record(id), let fr = l.tipFrames(r.tipID) {
            check(fr.buffers.count == 4 && fr.selection == .incremental, "GIH: one brush with 4 frames, incremental", "\(fr.buffers.count) \(fr.selection)")
        } else { check(false, "GIH animated tip") }
        // Procreate
        if let id = result("Dry Ink.brush")?.added.first, let r = l.record(id) {
            check(r.name == "Dry Ink", "Procreate .brush name from Brush.archive", r.name)
            check(r.params.textureEnabled && AppModel.shared.customPatterns.contains { $0.id == r.params.texturePatternID }, "Procreate Grain.png becomes the brush texture")
            check(r.params.scatterEnabled && abs(r.params.spacing - 0.2) < 1e-6, "Procreate settings mapped (spacing, jitter)")
            if let t = l.tipBuffer(r.tipID) { savePNG(t, "imported_tip_procreate"); check(gray(t, 32, 3) > 200 && gray(t, 0, 0) < 10, "Procreate Shape.png: white = paint") }
        }
        let set = result("Studio.brushset")
        check(names(set) == ["Studio 2", "Studio 1"], "Procreate .brushset: every brush, in brushset.plist order", "\(names(set))")
        check(set?.folderID.flatMap { l.index.folder($0)?.name } == "Studio Set", "brushset folder named from brushset.plist")
        // Krita
        if let id = result("Krita Auto.kpp")?.added.first, let r = l.record(id) {
            check(r.name == "Krita Auto" && r.tipID == "round" && abs(r.params.size - 42) < 0.5, "Krita auto brush → round tip with its diameter", "\(r.name) \(r.tipID) \(r.params.size)")
        }
        if let id = result("Krita Embedded.kpp")?.added.first, let r = l.record(id), let t = l.tipBuffer(r.tipID) {
            check(r.name == "Krita Embedded" && t.width == 30, "Krita preset with an embedded brush tip", "\(r.name) \(t.width)")
        }
        // Images
        for f in ["Rectangle.png", "Rectangle.jpg", "Rectangle.tiff"] {
            if let id = result(f)?.added.first, let r = l.record(id), let t = l.tipBuffer(r.tipID) {
                // dark rectangle on white: dark paints, trimmed? (images keep their frame, squared)
                check(t.width == 90 && gray(t, 45, 45) > 200 && gray(t, 2, 20) < 30, "\(f) as a tip: dark = paint", "\(t.width) \(gray(t, 45, 45)) \(gray(t, 2, 20))")
            }
        }
        check(l.index.root.folders.contains { $0.name == "Custom" }, "single images go into “Custom”")
        // contact sheet of the imported brushes
        let w = 320, h = 40
        let out = PixelBuffer(width: w * 2, height: (sheet.count + 1) / 2 * h)
        out.context.setFillColor(RGBA(gray: 0.96).cgColor); out.context.fill(CGRect(x: 0, y: 0, width: out.width, height: out.height))
        for (i, (_, img)) in sheet.enumerated() { out.drawImage(img, in: CGRect(x: (i % 2) * w, y: (i / 2) * h, width: w, height: h)) }
        out.markDirty()
        savePNG(out, "imported_strokes")
        print("brushlib: imported \(sheet.count) brushes from \(urls.count) files:\n" + summary)
        bigImport()
    }

    /// 250 brushes in one file, imported in the background with progress and a summary.
    static func bigImport() {
        var set = ImportedBrushSet(name: "Big Set")
        for i in 0..<250 {
            let k = "t\(i)"
            set.tips[k] = ImportedTipImage(.gray(ABRImporter.renderRound(diameter: 16 + i % 30, hardness: Double(i % 10) / 10, roundness: 0.5 + Double(i % 5) / 10, angle: Double(i))))
            set.brushes.append(ImportedBrush(name: "Brush \(i + 1)", folderPath: i < 100 ? ["Part A"] : ["Part B"], tipKey: k, params: BrushParams(size: 20, hardness: 1, spacing: 0.2)))
        }
        let url = tmp.appendingPathComponent("Kyle's Big Set.abr")
        try? ABRWriter.write(set).data.write(to: url)
        let l = lib("big", defaults: false)
        var sawProgress = false
        var done: [BrushLibrary.ImportResult]?
        l.importInBackground([url]) { done = $0 }
        let end = Date().addingTimeInterval(60)
        while done == nil && Date() < end {
            if l.importProgress != nil { sawProgress = true }
            UIFixesSelfTest.spin(0.02)
        }
        check(sawProgress, "a background import shows progress")
        check(done?.first?.added.count == 250, "250 brushes imported in the background", "\(done?.first?.added.count ?? -1)")
        check(l.lastImportSummary?.hasPrefix("Imported 250 brushes into “Kyle's Big Set”") == true, "big-set summary", l.lastImportSummary ?? "nil")
        check(l.undoName == "Import Brushes", "an import is one undo step")
    }

    // MARK: - Damaged files

    static func corruptInputs() {
        var seed: UInt64 = 0xC0FFEE
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        var parsed = 0, threw = 0
        let start = Date()
        for (name, data) in syntheticFiles() {
            let bytes = [UInt8](data)
            var variants: [Data] = []
            let step = max(1, bytes.count / 40)
            for cut in stride(from: 0, to: bytes.count, by: step) { variants.append(Data(bytes[0..<cut])) }
            for _ in 0..<60 {
                var b = bytes
                for _ in 0..<(1 + Int(next() % 12)) { b[Int(next() % UInt64(b.count))] = UInt8(truncatingIfNeeded: next()) }
                variants.append(Data(b))
            }
            for i in stride(from: 0, to: min(bytes.count - 4, 400), by: 7) {
                var b = bytes
                b[i] = 0xFF; b[i + 1] = 0xFF; b[i + 2] = 0xFF; b[i + 3] = 0xFF
                variants.append(Data(b))
            }
            for v in variants {
                do {
                    let s = try BrushImport.load(data: v, fileName: name)
                    // decode what came out the way the library does (images, frames)
                    for t in s.tips.values { for f in t.frames { _ = BrushLibrary.coverage(f) } }
                    parsed += 1
                } catch { threw += 1 }
            }
        }
        check(parsed + threw > 1500, "\(parsed + threw) truncated / corrupted brush files parsed without a crash (\(threw) rejected) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        // End to end: damaged files through the import command report errors instead of failing silently.
        let l = lib("corrupt", defaults: false)
        var urls: [URL] = []
        for (name, data) in syntheticFiles() {
            let u = tmp.appendingPathComponent("bad-" + name)
            try? Data(data.prefix(max(0, data.count / 3))).write(to: u)
            urls.append(u)
        }
        let empty = tmp.appendingPathComponent("empty.abr"); try? Data().write(to: empty); urls.append(empty)
        let junk = tmp.appendingPathComponent("junk.brushset"); try? Data((0..<500).map { UInt8($0 & 255) }).write(to: junk); urls.append(junk)
        let res = l.importFiles(urls)
        check(res.count == urls.count, "every damaged file gets a result")
        check(res.filter { $0.error != nil }.count >= urls.count / 2, "damaged files are reported", "\(res.filter { $0.error != nil }.count) of \(urls.count)")
        let summary = l.summary(res)
        check(summary.contains("empty.abr:") && summary.contains("junk.brushset:"), "the summary names the files that failed")
    }

    // MARK: - ImageCrat's own format

    static func brushSetRoundTrip() {
        let l = lib("icsrc")
        let gen = l.index.root.folders.first { $0.name == "Wet Media" }!.id
        let tip = ABRImporter.renderRound(diameter: 36, hardness: 0.4, roundness: 0.7, angle: 10)
        let custom = l.defineBrush(tip: tip, name: "Custom Oval", in: gen)!
        l.setFlags(custom, includesToolSettings: true, color: .some(RGBA(r: 0, g: 0.5, b: 1)))
        if let fr = l.addTip(frames: [tip, ABRImporter.renderRound(diameter: 36, hardness: 1, roundness: 0.3, angle: 0)], selection: .random) {
            var s = l.standaloneSettings(l.record(custom)!); s.tipID = fr
            l.saveSettings(s, to: custom)
        }
        let ids = l.index.brushIDs(inFolder: gen)
        let data = l.brushSetData(ids, name: "Wet Media")
        let url = tmp.appendingPathComponent("Wet Media.icbrushes")
        try? data.write(to: url)
        let back = lib("icdst", defaults: false)
        let res = back.importFiles([url])
        let added = res.first?.added ?? []
        check(added.count == ids.count, ".icbrushes round trip: every brush", "\(added.count) of \(ids.count) \(res.first?.error ?? "")")
        var mismatched: [String] = []
        for (a, b) in zip(ids, added) {
            guard let ra = l.record(a), let rb = back.record(b) else { continue }
            var pa = ra.params, pb = rb.params
            pb.dualTipID = pa.dualTipID; pb.texturePatternID = pa.texturePatternID; pb.texturePatternName = pa.texturePatternName
            if ra.name != rb.name || pa != pb || ra.includesToolSettings != rb.includesToolSettings || ra.color != rb.color { mismatched.append(ra.name + " " + diff(pa, pb)) }
        }
        check(mismatched.isEmpty, ".icbrushes keeps every setting, flag and colour", mismatched.joined(separator: "; "))
        if let rb = added.first(where: { back.record($0)?.name == "Custom Oval" }).flatMap({ back.record($0) }), let fr = back.tipFrames(rb.tipID) {
            check(fr.buffers.count == 2 && fr.selection == .random, ".icbrushes keeps animated tips", "\(fr.buffers.count)")
        } else { check(false, ".icbrushes custom brush") }
        // a newer major version is refused with a clear message
        var z = ZipWriter()
        z.add(name: "manifest.json", data: Data(#"{"format":"imagecrat-brushes","version":99,"name":"Future","brushes":[]}"#.utf8))
        do { _ = try BrushSetArchive.read(z.finish()); check(false, "a newer .icbrushes version is refused") }
        catch { check(true, "a newer .icbrushes version is refused: \((error as? LocalizedError)?.errorDescription ?? "")") }
    }
}
