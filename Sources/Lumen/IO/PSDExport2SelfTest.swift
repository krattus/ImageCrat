import AppKit
import ImageIO
import ImageCratCore

/// More exporter tests (part of `LUMEN_SELFTEST_ONLY=psdexport`; sub-filters `bits16`, `linked`, `txt2`, `relink`):
/// true 16-bit files, linked smart objects stored the way Photoshop stores them ('liFE' in 'lnkE', placed with 'SoLE'),
/// the document's text engine data ('Txt2') and fitting replaced / relinked smart-object contents into their box.
extension PSDExportSelfTest {
    // MARK: Byte-level helpers

    /// Global tagged blocks of a PSD / PSB (key, payload range).
    static func globalBlocks(_ data: Data) -> [(String, Range<Int>)] {
        let b = [UInt8](data)
        var c = PSDCursor(b)
        var out: [(String, Range<Int>)] = []
        do {
            _ = try c.fourCC(); let version = try c.u16(); try c.skip(6)
            let large = version == 2
            try c.skip(2 + 4 + 4 + 2 + 2)
            try c.skip(try c.u32())
            try c.skip(try c.u32())
            var lmi = try c.sub(try c.len(large: large))
            try lmi.skip(try lmi.len(large: large))
            try lmi.skip(try lmi.u32())
            while lmi.remaining >= 12 {
                guard try lmi.fourCC() == "8BIM" else { break }
                let key = try lmi.fourCC()
                let n = (large && PSDExport.longKeys.contains(key)) ? try lmi.u64() : try lmi.u32()
                let body = try lmi.sub(n)
                out.append((key, body.start..<body.end))
                try lmi.skip((4 - n % 4) % 4)
            }
        } catch {}
        return out
    }

    /// Payload ranges of every layer-level tagged block `key` (PSD files: 4-byte lengths), in file order. Only the
    /// document's own layers: the scan stops at the global blocks (embedded files hold layers of their own).
    static func layerBlocks(_ data: Data, _ key: String) -> [Range<Int>] {
        let b = [UInt8](data), pat = Array(("8BIM" + key).utf8)
        let stop = globalBlocks(data).first { !["Lr16", "Mt16"].contains($0.0) }.map { $0.1.lowerBound - 12 } ?? b.count
        var out: [Range<Int>] = []
        var i = 0
        while i + 12 <= stop {
            if b[i] == pat[0], Array(b[i..<(i + 8)]) == pat {
                let n = Int(b[i + 8]) << 24 | Int(b[i + 9]) << 16 | Int(b[i + 10]) << 8 | Int(b[i + 11])
                if n >= 0, i + 12 + n <= b.count { out.append((i + 12)..<(i + 12 + n)); i += 12 + n; continue }
            }
            i += 1
        }
        return out
    }

    /// Header channel count / depth and the merged image's compression word.
    static func header(_ data: Data) -> (channels: Int, depth: Int)? {
        guard data.count > 26 else { return nil }
        let b = [UInt8](data.prefix(26))
        return (Int(b[12]) << 8 | Int(b[13]), Int(b[22]) << 8 | Int(b[23]))
    }

    /// The text engine data of `Txt2` (a sequence of /key value pairs).
    static func txt2(_ data: Data) -> PSDEngineValue? {
        guard let r = globalBlocks(data).first(where: { $0.0 == "Txt2" })?.1 else { return nil }
        return try? PSDEngineParser.parse([0x3C, 0x3C] + Array([UInt8](data)[r]) + [0x3E, 0x3E])
    }

    /// TySh of each type layer (file order): text descriptor and its engine data.
    static func typeLayers(_ data: Data) -> [(PSDDescriptor, PSDEngineValue)] {
        let b = [UInt8](data)
        return layerBlocks(data, "TySh").compactMap { r in
            var c = PSDCursor(b, r)
            guard (try? c.skip(2 + 48 + 2)) != nil, let td = try? PSDDescriptor.readVersioned(Data(b[c.pos..<r.upperBound])),
                  case .data(_, let ed)? = td["EngineData"], let e = try? PSDEngineParser.parse([UInt8](ed)) else { return nil }
            return (td, e)
        }
    }

    // MARK: 16 bits

    static func testBits16(_ dir: URL) {
        var st = PSDExportSamples.shapes()
        st.layers.append(Layer(name: "Smooth gradient", content: .fill(FillContent(paint: .gradient(GradientFill(gradient: ColorGradient.presets[1], type: .linear, angle: 0))))))
        st.layers[st.layers.count - 1].opacity = 0.5
        st.bitDepth = .sixteen
        guard let rt = roundTrip(st, "bits16", dir, exact: false) else { return }
        let h = header(rt.data)
        check(h?.depth == 16, "16-bit: the header says 16 bits per channel (what Photoshop shows as 16 Bits/Channel)", "\(String(describing: h))")
        let keys = globalBlocks(rt.data).map(\.0)
        check(keys.contains("Lr16") && !keys.contains("Layr"), "16-bit: the layers are in 'Lr16' and the 8-bit layer section is empty", keys.joined(separator: ","))
        // layer channels: ZIP with prediction, as Photoshop writes 16-bit layers
        var comps: Set<Int> = []
        if let r = globalBlocks(rt.data).first(where: { $0.0 == "Lr16" })?.1 {
            let b = [UInt8](rt.data)
            var c = PSDCursor(b, r)
            var lens: [Int] = []
            if let n = try? c.i16() {
                for _ in 0..<abs(n) {
                    guard (try? c.skip(16)) != nil, let nc = try? c.u16() else { break }
                    for _ in 0..<nc { _ = try? c.i16(); if let l = try? c.u32() { lens.append(l) } }
                    _ = try? c.skip(12)
                    if let x = try? c.u32() { _ = try? c.skip(x) }
                }
                for l in lens { if var w = try? c.sub(l), l >= 2, let v = try? w.u16() { comps.insert(v) } }
            }
        }
        check(comps.subtracting([0]) == [3], "16-bit: layer channels use ZIP with prediction (compression 3)", "\(comps.sorted())")
        // the merged image: raw 16-bit (the system decoder reads only that), at real 16-bit precision
        let b = [UInt8](rt.data)
        let W = st.width, H = st.height
        let mergedStart = b.count - W * H * 2 * (h?.channels ?? 3) - 2
        let comp = mergedStart >= 0 ? Int(b[mergedStart]) << 8 | Int(b[mergedStart + 1]) : -1
        check(comp == 0, "16-bit: the merged image is stored uncompressed (Finder / Quick Look decode it)", "compression \(comp)")
        var wide = 0, total = 0
        if comp == 0 {
            var i = mergedStart + 2
            while i + 1 < b.count { let v = Int(b[i]) << 8 | Int(b[i + 1]); if v % 257 != 0 { wide += 1 }; total += 1; i += 2 }
        }
        metric("16-bit merged samples that are not widened 8-bit values: \(wide) of \(total)")
        check(wide > total / 50, "16-bit: the composite is rendered at 16 bits (gradients have more than 256 levels), not widened from 8 bits", "\(wide) of \(total)")
        if let src = CGImageSourceCreateWithData(rt.data as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            check((props[kCGImagePropertyDepth] as? Int) == 16, "16-bit: the system image decoder reports 16 bits per channel", "\(String(describing: props[kCGImagePropertyDepth]))")
            if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), let f8 = flatten(st) {
                let d = PSDImportSelfTest.diff(PixelBuffer(cgImage: cg), f8)
                check(d.mean < 1.5, "16-bit: the system decoder shows the right picture", "mean \(d.mean)")
            }
        } else { check(false, "16-bit: the system image decoder opens the file") }
        check(rt.back.bitDepth == .sixteen, "16-bit: Lumen reopens it as a 16-bit document")
        compare(st, rt.back, "16-bit (prediction)", mean: 1.0, bad: 0.006)
        // transparency: Photoshop's 'Mt16' marker and an alpha channel in the merged image
        var tr = DocumentState(width: 64, height: 40)
        tr.layers = [PSDExportSamples.shape("Blob", .ellipse(CGRect(x: 4, y: 4, width: 50, height: 30)), fill: .color(.red))]
        tr.bitDepth = .sixteen
        if let t = roundTrip(tr, "bits16_transparent", dir, exact: false) {
            check(globalBlocks(t.data).first?.0 == "Mt16" && header(t.data)?.channels == 4, "16-bit with transparency: 'Mt16' and a merged alpha channel, as Photoshop writes them")
        }
        // the Photoshop sample set's 16-bit file
        var sample = PSDExportSamples.shapes(); sample.bitDepth = .sixteen
        let url = dir.appendingPathComponent("09_check.psd")
        if (try? PSDWriter.write(sample, to: url)) != nil, let d = try? Data(contentsOf: url) {
            check(header(d)?.depth == 16 && PSDExportValidator.validate(d).problems.isEmpty, "the 16-bit sample document is written as a valid 16-bit PSD")
        }
    }

    // MARK: Linked smart objects

    /// A real Photoshop file with a linked smart object, when one is installed (none ships with Photoshop 2026: its
    /// generator test file has an empty 'lnkE').
    static func realLinkedSample() -> (URL, Data)? {
        var candidates: [String] = []
        if let p = ProcessInfo.processInfo.environment["LUMEN_PSD_LINKED_SAMPLE"] { candidates.append(p) }
        candidates.append("/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app/Contents/Required/Plug-ins/Generator/crema.generate/node_modules/generator-assets/test/resources/all-layer-types.psd")
        for p in candidates {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: p), options: .mappedIfSafe) else { continue }
            if globalBlocks(d).contains(where: { $0.0 == "lnkE" && $0.1.count > 16 }) { return (URL(fileURLWithPath: p), d) }
        }
        return nil
    }

    /// One 'liFE' / 'liFD' record read field by field (independently of the importer).
    struct LinkRecord {
        var type = "", version = 0, id = "", name = "", fileType = "", creator = "", dataSize = 0
        var link: PSDDescriptor? = nil
        var year = 0, month = 0, day = 0, fileSize = 0
        var trailing = 0
    }

    static func linkRecords(_ data: Data, _ r: Range<Int>) -> [LinkRecord] {
        let b = [UInt8](data)
        var c = PSDCursor(b, r)
        var out: [LinkRecord] = []
        while c.remaining >= 8 {
            guard let len = try? c.u64(), len > 0, len <= c.remaining, var e = try? c.sub(len) else { break }
            _ = try? c.skip((4 - len % 4) % 4)
            var rec = LinkRecord()
            do {
                rec.type = try e.fourCC(); rec.version = try e.u32(); rec.id = try e.pascal(pad: 1); rec.name = try e.unicode()
                rec.fileType = try e.fourCC(); rec.creator = try e.fourCC(); rec.dataSize = try e.u64()
                if try e.u8() != 0 { var dr = PSDDescriptorReader(Data(b[e.pos..<e.end])); _ = try dr.u32(); _ = try dr.descriptor(); try e.skip(dr.pos) }
                if rec.type == "liFE" {
                    var dr = PSDDescriptorReader(Data(b[e.pos..<e.end])); _ = try dr.u32(); rec.link = try dr.descriptor(); try e.skip(dr.pos)
                    if rec.version > 3 { rec.year = try e.u32(); rec.month = Int(try e.u8()); rec.day = Int(try e.u8()); try e.skip(2 + 8) }
                    rec.fileSize = try e.u64()
                    try e.skip(rec.dataSize)
                } else if rec.type == "liFD" { try e.skip(rec.dataSize) }
                if rec.version >= 5 { _ = try e.unicode() }
                if rec.version >= 6 { try e.skip(8) }
                if rec.version >= 7 { try e.skip(1) }
                rec.trailing = e.remaining
            } catch { rec.trailing = -1 }
            out.append(rec)
        }
        return out
    }

    static func testLinked(_ dir: URL) {
        let d = dir.appendingPathComponent("linked")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let images = d.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let file = images.appendingPathComponent("linked-source.png")
        try? PSDExportSamples.checker(100, 60).pngData()?.write(to: file)
        let st = PSDExportSamples.smart(linkedFile: file)
        check(PSDExport.writeExternalLinks, "linked smart objects are written as links by default")
        guard let rt = roundTrip(st, "linked", d, exact: false) else { return }
        let blocks = globalBlocks(rt.data)
        let lnkE = blocks.first { $0.0 == "lnkE" }, lnk2 = blocks.first { $0.0 == "lnk2" }
        check(lnkE != nil && lnk2 != nil, "the link is in 'lnkE' and the embedded files in 'lnk2' (Photoshop keeps them apart)", blocks.map(\.0).joined(separator: ","))
        let ext = lnkE.map { linkRecords(rt.data, $0.1) } ?? []
        let emb = lnk2.map { linkRecords(rt.data, $0.1) } ?? []
        check(emb.allSatisfy { $0.type == "liFD" } && !emb.isEmpty, "'lnk2' holds only embedded files ('liFD')")
        check(ext.count == 1, "'lnkE' holds one record", "\(ext.count)")
        if let r = ext.first {
            check(r.type == "liFE" && r.version == 7 && r.trailing == 0, "the record is a version 7 'liFE' that parses to its exact length", "\(r.type) v\(r.version) trailing \(r.trailing)")
            check(r.name == "linked-source.png\u{0}" || r.name == "linked-source.png", "the record carries the file name", r.name)
            check(r.fileType == "png " && r.creator == "\0\0\0\0", "Mac file type 'png ' and an empty creator, as Photoshop writes for PNG files", "'\(r.fileType)' '\(r.creator)'")
            check(r.dataSize == 0, "no embedded copy is stored with the link", "\(r.dataSize)")
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? -1
            check(r.fileSize == size, "the record stores the file's size", "\(r.fileSize) vs \(size)")
            let mod = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
            let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: mod)
            check(r.year == c.year && r.month == c.month && r.day == c.day, "the record stores the file's modification date", "\(r.year)-\(r.month)-\(r.day)")
            if let l = r.link {
                check(l.classID == "ExternalFileLink" && l.keys == ["descVersion", "Nm  ", "fullPath", "originalPath", "relPath"],
                      "the file reference is an 'ExternalFileLink' with descVersion, name, full path, original path and relative path, in that order", "\(l.classID): \(l.keys)")
                check(l.string("fullPath")?.hasPrefix("file:///") == true && l.string("fullPath")?.hasSuffix("images/linked-source.png") == true, "fullPath is the file URL", l.string("fullPath") ?? "")
                check(l.string("originalPath") == file.standardizedFileURL.path, "originalPath is the POSIX path", l.string("originalPath") ?? "")
                check(l.string("relPath") == "images/linked-source.png", "relPath is relative to the document's folder", l.string("relPath") ?? "")
            } else { check(false, "the record has a file reference descriptor") }
        }
        // the layer: placed with 'SoLE' (and the legacy 'PlLd'), referring to the record
        let sole = layerBlocks(rt.data, "SoLE")
        check(sole.count == 1, "the linked layer is placed with 'SoLE'; embedded layers keep 'SoLd'", "\(sole.count) SoLE, \(layerBlocks(rt.data, "SoLd").count) SoLd")
        if let r = sole.first, let desc = try? PSDDescriptor.readVersioned(Data([UInt8](rt.data)[(r.lowerBound + 8)..<r.upperBound])) {
            check(desc.string("Idnt")?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}")) == ext.first?.id, "'SoLE' refers to the 'liFE' record by its id")
            check(desc.object("Sz  ")?.double("Wdth") == 100 && desc.object("Sz  ")?.double("Hght") == 60, "'SoLE' stores the linked file's pixel size")
        }
        check(layer(rt.back, "Linked file")?.smart?.linkedURL?.standardizedFileURL == file.standardizedFileURL, "Lumen reopens the layer linked to the file")
        // moved together with the document: found through the relative path
        let moved = dir.appendingPathComponent("linked_moved")
        try? FileManager.default.removeItem(at: moved)
        try? FileManager.default.createDirectory(at: moved.appendingPathComponent("images"), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: file, to: moved.appendingPathComponent("images/linked-source.png"))
        if let res = try? PSDImporter.read(data: rt.data, name: "moved.psd", baseURL: moved) {
            // the full path still exists here; Photoshop prefers it too, and falls back to relPath when it is gone
            check(layer(res.state, "Linked file")?.smart?.linkedURL != nil, "the moved document still resolves its link")
        }
        // a missing file is embedded instead of written as a broken link
        var gone = st
        if let i = gone.layers.firstIndex(where: { $0.name == "Linked file" }) { gone.layers[i].smart?.linkedURL = d.appendingPathComponent("does-not-exist.png") }
        if let g = roundTrip(gone, "linked_missing", d, exact: false) {
            check(!globalBlocks(g.data).contains { $0.0 == "lnkE" } && layerBlocks(g.data, "SoLE").isEmpty, "a link to a missing file is embedded instead")
        }
        // compared with a real Photoshop linked smart object, when one is installed
        if let (url, real) = realLinkedSample(), let r = globalBlocks(real).first(where: { $0.0 == "lnkE" })?.1 {
            let recs = linkRecords(real, r)
            if let p = recs.first, let o = ext.first {
                check(p.type == o.type && p.link?.classID == o.link?.classID && p.link?.keys == o.link?.keys, "the 'liFE' layout matches Photoshop's (\(url.lastPathComponent))",
                      "\(p.type) v\(p.version) \(p.link?.keys ?? []) vs \(o.type) v\(o.version) \(o.link?.keys ?? [])")
            }
        } else {
            metric("no Photoshop sample with a linked smart object is installed (all-layer-types.psd only has an empty 'lnkE'); the layout follows the documented format")
            if let d = try? Data(contentsOf: URL(fileURLWithPath: "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app/Contents/Required/Plug-ins/Generator/crema.generate/node_modules/generator-assets/test/resources/all-layer-types.psd"), options: .mappedIfSafe) {
                let keys = globalBlocks(d).map(\.0)
                let embedded = globalBlocks(d).first { $0.0 == "lnk2" }.map { linkRecords(d, $0.1) } ?? []
                check(keys.contains("lnkE") && embedded.allSatisfy { $0.type == "liFD" }, "Photoshop's sample keeps embedded files in 'lnk2' and has a separate 'lnkE' block", keys.joined(separator: ","))
            }
        }
    }

    // MARK: Text engine data

    /// The type sample without its vertical layer (vertical type is not composed into 'Txt2').
    static func horizontalType() -> DocumentState {
        var st = PSDExportSamples.type()
        st.layers.removeAll { $0.text?.orientation == .vertical }
        return st
    }

    /// Problems between each type layer's 'TySh' and its story / frame in 'Txt2' (empty: consistent).
    static func txt2Problems(_ data: Data) -> [String] {
        guard let t2 = txt2(data) else { return ["no Txt2"] }
        let layers = typeLayers(data)
        let stories = t2["1"]?["1"]?.array ?? []
        let frames = t2["0"]?["8"]?["0"]?.array ?? []
        let fonts = (t2["0"]?["1"]?["0"]?.array ?? []).map { $0["0"]?["0"]?["0"]?.string ?? "" }
        var bad: [String] = []
        if stories.count != layers.count || frames.count != layers.count { bad.append("\(stories.count) stories, \(frames.count) frames, \(layers.count) layers") }
        for (td, e) in layers {
            guard let i = td["TextIndex"].flatMap({ v -> Int? in if case .integer(let n) = v { return Int(n) }; return nil }), i >= 0, i < stories.count else { bad.append("TextIndex"); continue }
            let s = stories[i]
            let name = td.string("Txt ") ?? "?"
            let text = e["EngineDict"]?["Editor"]?["Text"]?.string ?? ""
            if s["0"]?["0"]?.string != text { bad.append("\(name): text") }
            let n = (text as NSString).length
            // style runs: the same lengths and fonts as the layer's own engine data
            let srLen = e["EngineDict"]?["StyleRun"]?["RunLengthArray"]?.array.compactMap(\.int) ?? []
            let runs = s["0"]?["6"]?["0"]?.array ?? []
            if runs.compactMap({ $0["1"]?.int }) != srLen { bad.append("\(name): style run lengths") }
            let layerFonts = (e["ResourceDict"]?["FontSet"]?.array ?? []).map { $0["Name"]?.string ?? "" }
            let sheets = e["EngineDict"]?["StyleRun"]?["RunArray"]?.array ?? []
            for (k, r) in runs.enumerated() where k < sheets.count {
                let f0 = layerFonts[safe: sheets[k]["StyleSheet"]?["StyleSheetData"]?["Font"]?.int ?? -1] ?? "?"
                let f1 = fonts[safe: r["0"]?["0"]?["6"]?["0"]?.int ?? -1] ?? "?"
                let size0 = sheets[k]["StyleSheet"]?["StyleSheetData"]?["FontSize"]?.double, size1 = r["0"]?["0"]?["6"]?["1"]?.double
                if f0 != f1 || size0 != size1 { bad.append("\(name): run \(k) font \(f0)/\(f1) size \(String(describing: size0))/\(String(describing: size1))") }
            }
            let prLen = e["EngineDict"]?["ParagraphRun"]?["RunLengthArray"]?.array.compactMap(\.int) ?? []
            if (s["0"]?["5"]?["0"]?.array ?? []).compactMap({ $0["1"]?.int }) != prLen { bad.append("\(name): paragraph runs") }
            // composed lines: contiguous, covering the text, with as many glyphs and positions as characters
            let pc = s["1"]?["2"]?[0]
            if s["1"]?["0"]?[0]?["0"]?.int != i { bad.append("\(name): frame reference") }
            let lines = pc?["6"]?[0]?["6"]?[0]?["6"]?[0]?["6"]?.array ?? []
            var next = 0
            for ln in lines {
                guard let seg = ln["6"]?[0], let start = seg["16"]?.int, let count = seg["15"]?["0"]?.int else { bad.append("\(name): line"); continue }
                if start != next { bad.append("\(name): line starts at \(start), expected \(next)") }
                next = start + count
                var chars = 0
                for g in seg["6"]?.array ?? [] {
                    let c = g["10"]?["1"]?[0]?.int ?? -1
                    chars += c
                    if (g["21"]?["0"]?.array.count ?? -1) != c || (g["21"]?["1"]?.array.count ?? -1) != c + 1 { bad.append("\(name): glyph run arrays") }
                }
                if chars != count || (seg["15"]?["7"]?["7"]?.array.count ?? -1) != count { bad.append("\(name): line of \(count) characters has \(chars) in glyph runs") }
            }
            if next != n { bad.append("\(name): lines cover \(next) of \(n) characters") }
            // 'bounds' spans the composed lines (and the box of paragraph text)
            let isBox = frames[safe: i]?["0"]?["1"] != nil
            let tops = lines.map { ($0["10"]?.double ?? 0) + ($0["14"]?.double ?? 0) }
            if let b = td.object("bounds"), let bt = b.double("Top "), let minTop = tops.min(), abs(bt - (isBox ? min(0, minTop) : minTop)) > 0.01 {
                bad.append("\(name): bounds top \(bt) vs lines \(minTop)")
            }
        }
        return bad
    }

    static func testTxt2(_ dir: URL) {
        let d = dir.appendingPathComponent("txt2")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let st = horizontalType()
        guard let rt = roundTrip(st, "type_txt2", d, exact: false) else { return }
        guard let t2 = txt2(rt.data) else { check(false, "a document with type layers has 'Txt2'"); return }
        check(true, "a document with type layers has 'Txt2', and it parses as engine data")
        let layers = typeLayers(rt.data)
        let stories = t2["1"]?["1"]?.array ?? []
        let frames = t2["0"]?["8"]?["0"]?.array ?? []
        let fonts = (t2["0"]?["1"]?["0"]?.array ?? []).map { $0["0"]?["0"]?["0"]?.string ?? "" }
        check(stories.count == layers.count && frames.count == layers.count, "one story and one frame per type layer", "\(stories.count) stories, \(frames.count) frames, \(layers.count) layers")
        check(t2["98"]?["0"]?.int == 14 && t2["1"]?["4"]?["3"]?.string == "Photoshop", "version 14 and Photoshop's text engine version, as Photoshop 2026 writes")
        var bad = txt2Problems(rt.data)
        check(bad.isEmpty, "every story matches its layer: text, style runs and fonts, paragraph runs, frame, and lines that cover the text with one glyph and one position per character", bad.prefix(8).joined(separator: " | "))
        var all = PSDExportSamples.everything()
        all.layers = all.layers.map { l in
            var c = l
            if case .group(var g) = l.content { g.children.removeAll { $0.text?.orientation == .vertical }; c.content = .group(g) }
            return c
        }
        if let ev = roundTrip(all, "everything_txt2", d, exact: false) {
            let p = txt2Problems(ev.data)
            check(p.isEmpty, "a document with grouped type layers (and smart objects holding their own type) gets a consistent 'Txt2'", p.prefix(6).joined(separator: " | "))
        }
        // paragraph text has a box frame (its outline), point text a point frame
        if let i = layers.firstIndex(where: { $0.0.string("Txt ")?.hasPrefix("Paragraph") == true }) {
            let ti: Int? = { if case .integer(let n)? = layers[i].0["TextIndex"] { return Int(n) }; return nil }()
            let path = frames[safe: ti ?? -1]?["0"]?["1"]?["0"]?.doubles ?? []
            check(path.count == 32 && path.max() == 260, "paragraph text gets a box frame with its outline", "\(path.prefix(8))")
        }
        // Photoshop's line metrics: (0.5 em + half the cap height) above the baseline, the font box's descent below
        // (values from Photoshop's own composition of these layers)
        func lineTop(_ name: String) -> (Double, Double)? {
            guard let (td, _) = layers.first(where: { $0.0.string("Txt ")?.hasPrefix(name) == true }),
                  case .integer(let n)? = td["TextIndex"], let ln = stories[safe: Int(n)]?["1"]?["2"]?[0]?["6"]?[0]?["6"]?[0]?["6"]?[0]?["6"]?[0] else { return nil }
            return (ln["14"]?.double ?? .nan, ln["15"]?.double ?? .nan)
        }
        if FontLookup.installed("HelveticaNeue"), let (top, bottom) = lineTop("Right aligned") {
            check(abs(top + 20.56787) < 0.01 && abs(bottom - 11.54407) < 0.01, "Helvetica Neue 24 pt: line top and bottom as Photoshop computes them (−20.568, 11.544)", "\(top), \(bottom)")
        }
        if FontLookup.installed("Georgia"), let (top, bottom) = lineTop("Centred") {
            check(abs(top + 22.00732) < 0.01 && abs(bottom - 7.88379) < 0.01, "Georgia 26 pt: line top and bottom as Photoshop computes them (−22.007, 7.884)", "\(top), \(bottom)")
        }
        // right-aligned point text with tracking: the origin is the end of the line without the last tracking
        if let (td, _) = layers.first(where: { $0.0.string("Txt ")?.hasPrefix("Right aligned") == true }), let b = td.object("bounds") {
            check(abs(b.double("Rght") ?? 99) < 0.01 && (b.double("Left") ?? 0) < -100, "right-aligned text: 'bounds' ends at the origin (tracking after the last letter excluded), like Photoshop", "\(b.double("Left") ?? 0) … \(b.double("Rght") ?? 0)")
        }
        // TySh details Photoshop 2026 writes
        check(layers.allSatisfy { $0.0.keys == ["Txt ", "textGridding", "Ornt", "AntA", "TxMP", "bounds", "boundingBox", "TextIndex", "EngineData"] }, "'TySh' descriptors have Photoshop 2026's key order (with 'TxMP')")
        check(layers.allSatisfy { e in (e.1["ResourceDict"]?["FontSet"]?.array.last?["Name"]?.string) == "MyriadPro-Regular" }, "each layer's font set ends with Photoshop's default font, as Photoshop lists it")
        // round trip: Lumen still reads its files, and the same layer positions come back
        for l in st.layers where l.isText {
            guard let a = l.text, let b = layer(rt.back, l.name)?.text, PSDExportText.fontInfo(a.fontName).installed else { continue }
            let r0 = TextRenderer.docBounds(a), r1 = TextRenderer.docBounds(b)
            if !near(r0, r1, 1) { bad.append(l.name) }
        }
        check(bad.isEmpty, "type layers come back in place with 'Txt2' written (within 1 px)", bad.joined(separator: ", "))
        // documents with vertical type keep the old behaviour: no 'Txt2'
        if let v = roundTrip(PSDExportSamples.type(), "type_vertical", d, exact: false) {
            check(txt2(v.data) == nil, "a document with vertical type gets no 'Txt2' (vertical type is not composed here)")
        }
    }

    // MARK: Relink / Replace Contents

    static func withDocument(_ st: DocumentState, _ body: (Document) -> Void) {
        let app = AppModel.shared
        let d = Document(state: st, name: "psdexport-relink")
        let prevDocs = app.documents, prevActive = app.activeDocumentID
        app.documents.append(d); app.activeDocumentID = d.id
        body(d)
        app.documents = prevDocs.filter { p in app.documents.contains { $0 === p } }
        app.activeDocumentID = prevActive
    }

    static func testRelinkFit(_ dir: URL) {
        let d = dir.appendingPathComponent("relink")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let wide = d.appendingPathComponent("wide.png"), tall = d.appendingPathComponent("tall.png"), same = d.appendingPathComponent("same.png")
        try? PSDExportSamples.checker(400, 100).pngData()?.write(to: wide)
        try? PSDExportSamples.checker(60, 240).pngData()?.write(to: tall)
        try? PSDExportSamples.checker(160, 120).pngData()?.write(to: same)
        let img = PSDExportSamples.checker(160, 120)
        let rotated = Quad(rect: CGRect(x: -80, y: -60, width: 160, height: 120)).applying(CGAffineTransform(rotationAngle: 0.5).scaledBy(x: 1.5, y: 1.5).concatenating(CGAffineTransform(translationX: 300, y: 200)))
        let stretched = Quad(rect: CGRect(x: 20, y: 20, width: 320, height: 60))   // 160×120 shown 2× wide, ½ high
        let persp = Quad(tl: CGPoint(x: 100, y: 50), tr: CGPoint(x: 400, y: 80), br: CGPoint(x: 380, y: 300), bl: CGPoint(x: 120, y: 260))
        func fits(_ q0: Quad, _ q1: Quad, _ size: CGSize) -> (Bool, String) {
            // in the box's own frame (edges measured as fitSource does) the new quad is a centred rectangle with the
            // file's aspect ratio that touches two opposite sides
            let w = (q0.tl.distance(to: q0.tr) + q0.bl.distance(to: q0.br)) / 2, h = (q0.tl.distance(to: q0.bl) + q0.tr.distance(to: q0.br)) / 2
            guard let H = Homography(from: q0, to: Quad(rect: CGRect(x: 0, y: 0, width: w, height: h))) else { return (false, "degenerate") }
            let p = q1.mapped(H.apply)
            let r = CGRect.bounding(p.points)
            let rectangular = p.points.enumerated().allSatisfy { i, pt in pt.distance(to: Quad(rect: r).points[i]) < 0.01 }
            let aspect = abs(r.width / r.height - size.width / size.height) < 0.001
            let centred = abs(r.midX - w / 2) < 0.01 && abs(r.midY - h / 2) < 0.01
            let touches = abs(r.width - w) < 0.01 || abs(r.height - h) < 0.01
            let inside = r.minX > -0.01 && r.minY > -0.01 && r.maxX < w + 0.01 && r.maxY < h + 0.01
            return (rectangular && aspect && centred && touches && inside, "\(r) in \(w)×\(h)")
        }
        for (label, q) in [("rotated + scaled", rotated), ("stretched", stretched), ("perspective", persp)] {
            var st = PSDExportSamples.base(560, 400)
            st.layers.append(Layer(name: "SO", content: .smartObject(SmartObjectContent(source: .image(img), quad: q, sourceName: "checker.png"))))
            withDocument(st) { doc in
                guard let id = doc.state.layers.last?.id else { return }
                // default: fit to the current bounds
                let h0 = doc.history.count
                check(AppActions.replaceSmartContents(of: id, in: doc, with: wide), "relink fit (\(label)): Replace Contents loads the file")
                if let so = doc.state.layer(id)?.smart {
                    let (ok, why) = fits(q, so.quad, CGSize(width: 400, height: 100))
                    check(ok && so.source.size == CGSize(width: 400, height: 100), "relink fit (\(label)): a wider file fits the box — aspect ratio kept, centred, rotation / perspective kept", why)
                }
                check(doc.history.count == h0 + 1, "relink fit (\(label)): one history step")
                doc.undo()
                check(doc.state.layer(id)?.smart?.quad == q && doc.state.layer(id)?.smart?.source.size == CGSize(width: 160, height: 120), "relink fit (\(label)): undo restores the box and the contents")
                // a taller file: limited by the height
                _ = AppActions.replaceSmartContents(of: id, in: doc, with: tall)
                if let so = doc.state.layer(id)?.smart { let (ok, why) = fits(q, so.quad, CGSize(width: 60, height: 240)); check(ok, "relink fit (\(label)): a taller file fits the box's height", why) }
                doc.undo()
                // same size: nothing moves
                _ = AppActions.replaceSmartContents(of: id, in: doc, with: same)
                check(doc.state.layer(id)?.smart?.quad == q, "relink fit (\(label)): a file of the same size keeps the box exactly")
                doc.undo()
                // keep scale (like Photoshop): the box follows the file's pixel size at the object's scale
                doc.updateLayer(id) { $0.smart?.contentFit = .keepScale }
                doc.commit("fit option")
                _ = AppActions.replaceSmartContents(of: id, in: doc, with: wide)
                if let so = doc.state.layer(id)?.smart, let place = Homography(from: Quad(rect: CGRect(x: 0, y: 0, width: 160, height: 120)), to: q) {
                    let want = Quad(rect: CGRect(x: 0, y: 0, width: 400, height: 100)).mapped(place.apply)
                    check(zip(so.quad.points, want.points).allSatisfy { $0.distance(to: $1) < 0.01 }, "relink keep scale (\(label)): the object keeps its scale, rotation and perspective, and grows with the file")
                }
                doc.undo()
                check(doc.state.layer(id)?.smart?.quad == q, "relink keep scale (\(label)): undo restores the box")
                // Relink to File and Update Modified Content follow the same setting
                doc.undo()   // back to fit
                AppActions.relink(id, in: doc, to: wide)
                if let so = doc.state.layer(id)?.smart {
                    let (ok, why) = fits(q, so.quad, CGSize(width: 400, height: 100))
                    check(ok && so.linkedURL == wide, "relink fit (\(label)): Relink to File fits a file of another size into the box", why)
                }
                // the linked file changes size on disk: Update Modified Content fits it into the current box
                let before = doc.state.layer(id)?.smart?.quad ?? q
                try? PSDExportSamples.checker(200, 200).pngData()?.write(to: wide)
                AppActions.updateModifiedLinkedContent(doc, all: true)
                if let so = doc.state.layer(id)?.smart {
                    let (ok, why) = fits(before, so.quad, CGSize(width: 200, height: 200))
                    check(ok && so.source.size == CGSize(width: 200, height: 200), "relink fit (\(label)): Update Modified Content fits the resized file into the current box", why)
                }
                try? PSDExportSamples.checker(400, 100).pngData()?.write(to: wide)
            }
        }
        check(SmartObjectContent(source: .image(img), quad: rotated).contentFit == nil, "new smart objects fit replaced contents by default")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
