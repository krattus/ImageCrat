import Foundation

/// ImageCrat's own brush-set file (`.icbrushes`): a ZIP (stored entries) holding `manifest.json` and the images.
///
///     {
///       "format": "imagecrat-brushes", "version": 1, "name": "My Brushes",
///       "brushes": [{"name": …, "folder": ["Group", …], "tip": "<key>" | null, "params": {BrushParams},
///                    "color": {"r","g","b","a"} | null, "includesSize": true, "includesToolSettings": false}],
///       "tips": {"<key>": {"frames": ["tips/<key>_0.png", …], "kinds": ["gray" | "encoded", …],
///                          "selection": "incremental"}},
///       "patterns": [{"id": …, "name": …, "file": "patterns/<id>.png", "kind": "gray" | "rgba" | "encoded"}]
///     }
///
/// Gray images are written as 8-bit gray PNGs (coverage, 255 = paint), RGBA patterns as RGBA PNGs, and `.encoded`
/// images verbatim with their own extension. `version` is the major version: readers reject newer majors and accept
/// any missing optional field (new optional keys can be added without a version bump). Reading never trusts the
/// manifest: unknown or broken entries are skipped and reported in `skipped`.
package enum BrushSetArchive {
    package static let formatID = "imagecrat-brushes"
    package static let currentVersion = 1
    package static let fileExtension = "icbrushes"
    package static let maxBrushes = 100_000
    package static let maxFramesPerTip = 4096

    // MARK: Manifest model (tolerant decoding)

    private struct ManifestBrush: Codable {
        var name: String?
        var folder: [String]?
        var tip: String?
        var params: BrushParams?
        var color: RGBA?
        var includesSize: Bool?
        var includesToolSettings: Bool?
        init(name: String?, folder: [String]?, tip: String?, params: BrushParams?, color: RGBA?, includesSize: Bool?,
             includesToolSettings: Bool?) {
            self.name = name; self.folder = folder; self.tip = tip; self.params = params; self.color = color
            self.includesSize = includesSize; self.includesToolSettings = includesToolSettings
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            folder = try? c.decodeIfPresent([String].self, forKey: .folder)
            tip = try? c.decodeIfPresent(String.self, forKey: .tip)
            params = try? c.decodeIfPresent(BrushParams.self, forKey: .params)
            color = try? c.decodeIfPresent(RGBA.self, forKey: .color)
            includesSize = try? c.decodeIfPresent(Bool.self, forKey: .includesSize)
            includesToolSettings = try? c.decodeIfPresent(Bool.self, forKey: .includesToolSettings)
        }
    }

    private struct ManifestTip: Codable {
        var frames: [String]
        var kinds: [String]?
        var selection: String?
        init(frames: [String], kinds: [String]?, selection: String?) { self.frames = frames; self.kinds = kinds; self.selection = selection }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            frames = (try? c.decodeIfPresent([String].self, forKey: .frames)) ?? []
            kinds = try? c.decodeIfPresent([String].self, forKey: .kinds)
            selection = try? c.decodeIfPresent(String.self, forKey: .selection)
        }
    }

    private struct ManifestPattern: Codable {
        var id: String
        var name: String?
        var file: String
        var kind: String?
        init(id: String, name: String?, file: String, kind: String?) { self.id = id; self.name = name; self.file = file; self.kind = kind }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            file = (try? c.decodeIfPresent(String.self, forKey: .file)) ?? ""
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        }
    }

    /// Decodes array elements one by one so a single broken element doesn't fail the whole array.
    private struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct Manifest: Encodable {
        var format: String
        var version: Int
        var name: String
        var brushes: [ManifestBrush]
        var tips: [String: ManifestTip]
        var patterns: [ManifestPattern]
    }

    private struct ManifestIn: Decodable {
        var format: String?
        var version: Int?
        var name: String?
        var brushes: [ManifestBrush]
        var tips: [String: ManifestTip]
        var patterns: [ManifestPattern]
        enum CodingKeys: String, CodingKey { case format, version, name, brushes, tips, patterns }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try? c.decodeIfPresent(String.self, forKey: .format)
            if let v = try? c.decodeIfPresent(Int.self, forKey: .version) { version = v }
            else if let d = try? c.decodeIfPresent(Double.self, forKey: .version), d.isFinite, abs(d) < 1e9 { version = Int(d) }
            else if let s = try? c.decodeIfPresent(String.self, forKey: .version) {
                version = Int(s.split(separator: ".").first.map(String.init) ?? "")
            } else { version = nil }
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            brushes = ((try? c.decodeIfPresent([Lenient<ManifestBrush>].self, forKey: .brushes)) ?? nil)?.compactMap(\.value) ?? []
            tips = ((try? c.decodeIfPresent([String: Lenient<ManifestTip>].self, forKey: .tips)) ?? nil)?
                .compactMapValues(\.value) ?? [:]
            patterns = ((try? c.decodeIfPresent([Lenient<ManifestPattern>].self, forKey: .patterns)) ?? nil)?.compactMap(\.value) ?? []
        }
    }

    // MARK: Write

    private static func sanitized(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let t = String(s.map { allowed.contains($0) ? $0 : "_" }.prefix(48))
        return t.isEmpty ? "x" : t
    }

    /// File extension for encoded image bytes.
    package static func imageExtension(_ d: Data) -> String {
        let b = [UInt8](d.prefix(12))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "gif" }
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A) { return "tif" }
        if b.count >= 4, b[0] == 0x38, b[1] == 0x42, b[2] == 0x50, b[3] == 0x53 { return "psd" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "bmp" }
        return "bin"
    }

    package static func write(_ set: ImportedBrushSet) -> Data {
        var zip = ZipWriter()
        var tips: [String: ManifestTip] = [:]
        for (i, key) in set.tips.keys.sorted().enumerated() {
            guard let tip = set.tips[key] else { continue }
            var frames: [String] = [], kinds: [String] = []
            let base = "tips/\(i)-\(sanitized(key))"
            for (f, img) in tip.frames.enumerated() {
                switch img {
                case .gray(let buf):
                    let path = "\(base)_\(f).png"
                    zip.add(name: path, data: PNGCodec.encode(buf.format == .gray ? buf : BrushTipImaging.grayCoverage(fromRGBA: buf)))
                    frames.append(path); kinds.append("gray")
                case .encoded(let d):
                    let path = "\(base)_\(f).\(imageExtension(d))"
                    zip.add(name: path, data: d)
                    frames.append(path); kinds.append("encoded")
                }
            }
            tips[key] = ManifestTip(frames: frames, kinds: kinds, selection: tip.selection.rawValue)
        }
        var patterns: [ManifestPattern] = []
        for (i, p) in set.patterns.enumerated() {
            let base = "patterns/\(i)-\(sanitized(p.id))"
            switch p.image {
            case .gray(let buf):
                let path = "\(base).png"
                zip.add(name: path, data: PNGCodec.encode(buf))
                patterns.append(ManifestPattern(id: p.id, name: p.name, file: path, kind: buf.format == .gray ? "gray" : "rgba"))
            case .encoded(let d):
                let path = "\(base).\(imageExtension(d))"
                zip.add(name: path, data: d)
                patterns.append(ManifestPattern(id: p.id, name: p.name, file: path, kind: "encoded"))
            }
        }
        let brushes = set.brushes.map {
            ManifestBrush(name: $0.name, folder: $0.folderPath, tip: $0.tipKey, params: $0.params, color: $0.color,
                          includesSize: $0.includesSize, includesToolSettings: $0.includesToolSettings)
        }
        let manifest = Manifest(format: formatID, version: currentVersion, name: set.name, brushes: brushes, tips: tips, patterns: patterns)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = (try? enc.encode(manifest)) ?? Data("{\"format\":\"\(formatID)\",\"version\":\(currentVersion)}".utf8)
        // The manifest goes last so the images precede it; readers use the central directory anyway.
        zip.add(name: "manifest.json", data: json)
        return zip.finish()
    }

    // MARK: Read

    /// True when the zip holds an ImageCrat manifest.
    package static func isBrushSetArchive(_ zip: ZipReader) -> Bool { manifestEntry(zip) != nil }

    private static func manifestEntry(_ zip: ZipReader) -> ZipReader.Entry? {
        zip.entries.filter { !$0.isMetadataJunk && $0.fileName.lowercased() == "manifest.json" }
            .min { $0.name.split(separator: "/").count < $1.name.split(separator: "/").count }
    }

    package static func read(_ data: Data) throws -> ImportedBrushSet {
        try read(zip: try ZipReader(data: data), fallbackName: "Brushes")
    }

    package static func read(zip: ZipReader, fallbackName: String) throws -> ImportedBrushSet {
        guard let me = manifestEntry(zip) else { throw BrushImportError.malformed("manifest.json missing") }
        guard me.uncompressedSize <= 64 << 20 else { throw BrushImportError.malformed("manifest too large") }
        let md = try zip.data(for: me)
        let m: ManifestIn
        do { m = try JSONDecoder().decode(ManifestIn.self, from: md) } catch { throw BrushImportError.malformed("manifest.json") }
        guard m.format == nil || m.format == formatID else { throw BrushImportError.unsupportedFormat("This archive") }
        let version = m.version ?? 1
        guard version <= currentVersion else { throw BrushImportError.unsupportedVersion(version) }
        let prefix = me.directory.isEmpty ? "" : me.directory + "/"
        func file(_ path: String) -> Data? { try? zip.data(for: prefix + path) }

        var set = ImportedBrushSet(name: (m.name?.isEmpty == false ? m.name! : fallbackName), format: "ImageCrat brush set")
        for (key, t) in m.tips {
            var frames: [BrushImageData] = []
            for (f, path) in t.frames.prefix(maxFramesPerTip).enumerated() {
                guard let d = file(path) else { continue }
                let kind = (t.kinds != nil && f < t.kinds!.count) ? t.kinds![f] : nil
                if kind == "encoded" { frames.append(.encoded(d)); continue }
                if let g = PNGCodec.decodeGrayscale(d) { frames.append(.gray(g)) }
                else if kind == "gray", let c = PNGCodec.decodeCoverage(d) { frames.append(.gray(c)) }
                else { frames.append(.encoded(d)) }
            }
            if frames.isEmpty { set.skipped.append("Tip \(key): image missing"); continue }
            set.tips[key] = ImportedTipImage(frames: frames, selection: BrushFrameSelection(rawValue: t.selection ?? "") ?? .incremental)
        }
        for p in m.patterns {
            guard !p.id.isEmpty, let d = file(p.file) else { set.skipped.append("Pattern \(p.name ?? p.id): image missing"); continue }
            let img: BrushImageData
            switch p.kind {
            case "encoded": img = .encoded(d)
            case "gray": img = PNGCodec.decodeGrayscale(d).map { .gray($0) } ?? (PNGCodec.decode(d).map { .gray($0) } ?? .encoded(d))
            default: img = PNGCodec.decode(d).map { .gray($0) } ?? .encoded(d)
            }
            set.patterns.append(ImportedPattern(id: p.id, name: p.name ?? p.id, image: img))
        }
        for (i, b) in m.brushes.prefix(maxBrushes).enumerated() {
            var params = b.params ?? BrushParams()
            params.sanitize()
            var tipKey = b.tip
            if let k = tipKey, set.tips[k] == nil {
                set.skipped.append("\(b.name ?? "Brush \(i + 1)"): tip image missing, using a round tip")
                tipKey = nil
            }
            set.brushes.append(ImportedBrush(name: b.name ?? "Brush \(i + 1)", folderPath: b.folder ?? [], tipKey: tipKey,
                                             params: params, color: b.color, includesSize: b.includesSize ?? true,
                                             includesToolSettings: b.includesToolSettings ?? false))
        }
        return set
    }
}
