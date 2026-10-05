import Foundation

/// Procreate brushes.
///
/// * `.brush`: a zip holding `Brush.archive` (NSKeyedArchiver binary plist, root object `$top.root`), `Shape.png`,
///   `Grain.png` and optionally `QuickLook/Thumbnail.png`, either at the top level or inside one folder.
/// * `.brushset`: a zip with one folder per brush (UUID names), each holding the files above, plus `brushset.plist`
///   ({"name": …, "brushes": [folder names in display order]}).
///
/// Images: Shape.png is white = paint (luminance composited over black, i.e. alpha × luminance for images with
/// transparency); Grain.png becomes a gray pattern with the same convention, attached as the brush texture. Images the
/// portable PNG decoder cannot read are passed on as `.encoded` for the app to decode.
///
/// The archive is read defensively: only keys that exist and have the right type are used, and a brush whose archive
/// cannot be read is still imported with its shape and default settings. The setting mappings are approximations
/// (Procreate's internal units are undocumented) and are documented at `mapSettings`.
package enum ProcreateBrush {
    /// A brush folder inside the zip.
    private struct Folder {
        var path: String          // "" = archive top level
        var archive: ZipReader.Entry?
        var shape: ZipReader.Entry?
        var grain: ZipReader.Entry?
    }

    package static func isProcreate(_ zip: ZipReader) -> Bool {
        zip.entries.contains { e in
            !e.isMetadataJunk && ["brush.archive", "shape.png", "brushset.plist"].contains(e.fileName.lowercased())
        }
    }

    package static func read(data: Data, name: String) throws -> ImportedBrushSet {
        try read(zip: try ZipReader(data: data), name: name)
    }

    package static func read(zip: ZipReader, name: String) throws -> ImportedBrushSet {
        // Collect brush folders: every directory that holds a Brush.archive or a Shape.png (ignoring the "Reset" copies
        // Procreate keeps of a brush's original settings).
        var folders: [String: Folder] = [:]
        var order: [String] = []
        for e in zip.entries where !e.isMetadataJunk {
            let file = e.fileName.lowercased()
            guard file == "brush.archive" || file == "shape.png" || file == "grain.png" else { continue }
            let dir = e.directory
            if dir.split(separator: "/").last.map({ $0.lowercased() == "reset" }) == true { continue }
            if folders[dir] == nil { folders[dir] = Folder(path: dir); order.append(dir) }
            switch file {
            case "brush.archive": folders[dir]?.archive = e
            case "shape.png": folders[dir]?.shape = e
            default: folders[dir]?.grain = e
            }
        }
        order = order.filter { folders[$0]?.archive != nil || folders[$0]?.shape != nil }
        guard !order.isEmpty else { throw BrushImportError.noBrushes }

        var set = ImportedBrushSet(name: name, format: order.count > 1 ? "Procreate brush set" : "Procreate brush")
        // brushset.plist: set name and display order.
        if let pe = zip.entries.first(where: { !$0.isMetadataJunk && $0.fileName.lowercased() == "brushset.plist" }),
           let pd = try? zip.data(for: pe), let plist = try? BinaryPlist.parse(pd) {
            if let n = plist["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { set.name = n }
            if let list = plist["brushes"]?.array?.compactMap({ $0.string }) {
                let prefix = pe.directory.isEmpty ? "" : pe.directory + "/"
                var ranked: [String] = []
                for id in list {
                    let full = prefix + id
                    if let hit = order.first(where: { $0 == full || $0 == id || $0.lowercased() == full.lowercased() }),
                       !ranked.contains(hit) { ranked.append(hit) }
                }
                order = ranked + order.filter { !ranked.contains($0) }
            }
        }

        var usedKeys = Set<String>()
        for (index, path) in order.enumerated() {
            guard let f = folders[path] else { continue }
            let label = "Brush \(index + 1)"
            var key = path.split(separator: "/").last.map(String.init) ?? ""
            if key.isEmpty { key = "brush\(index)" }
            while usedKeys.contains(key) { key += "_\(index)" }
            usedKeys.insert(key)

            var settings: PlistValue? = nil
            if let a = f.archive, let ad = try? zip.data(for: a) { settings = BinaryPlist.unarchiveRoot(ad) }
            var tipImage: BrushImageData? = nil
            var tipSide = 0
            if let s = f.shape {
                do {
                    let sd = try zip.data(for: s)
                    if let img = PNGCodec.decode(sd) {
                        let cov = BrushTipImaging.luminanceOverBlack(img)
                        tipSide = max(cov.width, cov.height)
                        tipImage = .gray(BrushTipImaging.squareGray(cov))
                    } else {
                        tipImage = .encoded(sd)
                    }
                } catch {
                    set.skipped.append("\(label): shape image unreadable (\((error as? LocalizedError)?.errorDescription ?? "error"))")
                }
            }
            var params = BrushParams()
            params.hardness = 1
            if tipSide > 0 { params.size = Double(min(tipSide, 120)) }
            if let st = settings { mapSettings(st, into: &params) }
            var brushName = settings?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if brushName.isEmpty { brushName = order.count == 1 ? name : label }

            if let g = f.grain, let gd = try? zip.data(for: g) {
                let pattern: BrushImageData
                if let img = PNGCodec.decode(gd) { pattern = .gray(BrushTipImaging.luminanceOverBlack(img)) } else { pattern = .encoded(gd) }
                set.patterns.append(ImportedPattern(id: key, name: "\(brushName) Grain", image: pattern))
                params.textureEnabled = true
                params.texturePatternID = key
                params.texturePatternName = "\(brushName) Grain"
            }
            params.sanitize()
            var tipKey: String? = nil
            if let t = tipImage { set.tips[key] = ImportedTipImage(t); tipKey = key }
            set.brushes.append(ImportedBrush(name: brushName, tipKey: tipKey, params: params, includesSize: true,
                                             includesToolSettings: false))
        }
        guard !set.brushes.isEmpty else { throw BrushImportError.noBrushes }
        return set
    }

    /// Maps Brush.archive settings onto `BrushParams` (keys that are missing keep their defaults):
    /// * `paintSize` (0…1 fraction of the maximum size): size = paintSize × maxPx, where maxPx = 500 by default, `maxSize`
    ///   when that is > 1.5 (pixels) or 500 × maxSize when it is a 0…1 fraction. A paintSize > 1 is taken as pixels.
    /// * `plotSpacing` (0…1) → spacing = max(0.01, plotSpacing) (linear, fraction of the diameter).
    /// * `plotJitter` (0…1) → scatter = 2 × plotJitter.
    /// * `shapeRotation`: |v| > 1 is a fixed angle in degrees; otherwise it is Procreate's "follow stroke" amount, and
    ///   |v| ≥ 0.5 sets the angle control to the stroke direction.
    /// * `shapeScatter` → angleJitter; `shapeFlipXJitter` / `shapeFlipYJitter` → flip jitter; `shapeRoundness` → roundness.
    /// * `dynamicsPressureSize` → pressure size (minDiameter = 1 − v); `dynamicsPressureOpacity` → pressure opacity
    ///   (minOpacity = 1 − v); `dynamicsJitterSize` / `dynamicsJitterOpacity` → size / opacity jitter;
    ///   hue / saturation / lightness (brightness) jitter → colour dynamics.
    /// * `grainScale` / `textureScale` → textureScale; `grainDepth` → textureDepth; `textureMovement` ≥ 0.5 (moving
    ///   grain) → texture each tip, else static texture.
    /// * `plotSmoothing` / `streamLine` → smoothing; `paintOpacity` → opacity.
    /// * `shapeRandomise` (per-stroke random start rotation) has no equivalent and is ignored.
    package static func mapSettings(_ s: PlistValue, into p: inout BrushParams) {
        func num(_ keys: String...) -> Double? {
            for k in keys { if let v = s[k]?.double, v.isFinite { return v } }
            return nil
        }
        if let ps = num("paintSize") {
            if ps > 1 {
                p.size = ps
            } else {
                var maxPx = 500.0
                if let m = num("maxSize") { maxPx = m > 1.5 ? m : (m > 0 ? 500 * m : 500) }
                p.size = max(1, ps * maxPx)
            }
        }
        if let v = num("plotSpacing") { p.spacing = max(0.01, v) }
        if let v = num("plotJitter"), v > 0 { p.scatterEnabled = true; p.scatter = v * 2 }
        if let v = num("shapeRotation") {
            if abs(v) > 1 { p.angle = v.truncatingRemainder(dividingBy: 360) }
            else if abs(v) >= 0.5 { p.shapeEnabled = true; p.angleControl = BrushControlParam(source: .direction) }
        }
        if let v = num("shapeScatter"), v > 0 { p.shapeEnabled = true; p.angleJitter = min(1, v) }
        if let v = num("shapeFlipXJitter"), v > 0 { p.shapeEnabled = true; p.flipXJitter = true }
        if let v = num("shapeFlipYJitter"), v > 0 { p.shapeEnabled = true; p.flipYJitter = true }
        if let v = num("shapeRoundness"), v > 0, v <= 1 { p.roundness = v }
        if let v = num("dynamicsPressureSize") {
            p.pressureSize = v > 0
            if v > 0 { p.shapeEnabled = true; p.sizeControl = BrushControlParam(source: .pressure); p.minDiameter = max(0, 1 - v) }
        }
        if let v = num("dynamicsPressureOpacity") {
            p.pressureOpacity = v > 0
            if v > 0 { p.transferEnabled = true; p.opacityControl = BrushControlParam(source: .pressure); p.minOpacity = max(0, 1 - v) }
        }
        if let v = num("dynamicsJitterSize"), v > 0 { p.shapeEnabled = true; p.sizeJitter = v }
        if let v = num("dynamicsJitterOpacity"), v > 0 { p.transferEnabled = true; p.opacityJitter = v }
        if let v = num("dynamicsJitterHue", "hueJitter"), v > 0 { p.colorEnabled = true; p.hueJitter = v }
        if let v = num("dynamicsJitterSaturation", "saturationJitter"), v > 0 { p.colorEnabled = true; p.saturationJitter = v }
        if let v = num("dynamicsJitterLightness", "dynamicsJitterBrightness", "lightnessJitter", "brightnessJitter"), v > 0 {
            p.colorEnabled = true; p.brightnessJitter = v
        }
        if let v = num("grainScale", "textureScale"), v > 0 { p.textureScale = v }
        if let v = num("grainDepth"), v >= 0 { p.textureDepth = v }
        if let v = num("textureMovement") { p.textureEachTip = v >= 0.5 }
        if let v = num("plotSmoothing", "streamLine") { p.smoothing = v }
        if let v = num("paintOpacity") { p.opacity = v }
    }
}
