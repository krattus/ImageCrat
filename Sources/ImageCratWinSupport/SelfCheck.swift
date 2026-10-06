import Foundation
import ImageCratCore

/// The built-in battery behind "Help ▸ Run Self-Check" and `imagecrat-cli selfcheck`: decodes small files embedded in
/// the executable, round-trips the writers, imports brush files built in code and runs the pixel algorithms.
package enum SelfCheck {
    package struct Result {
        package var name: String
        package var passed: Bool
        package var detail: String
        package var milliseconds: Double
    }

    package struct Failure: Error, CustomStringConvertible {
        package var description: String
        init(_ s: String) { description = s }
    }

    static func expect(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw Failure(what()) } }

    /// Every check, in order. `progress` is called before each one (index, count, name).
    package static func run(progress: ((Int, Int, String) -> Void)? = nil) -> [Result] {
        let all = checks
        var out: [Result] = []
        for (i, (name, body)) in all.enumerated() {
            progress?(i, all.count, name)
            let t0 = Date()
            var passed = true
            var detail = ""
            do { detail = try body() } catch {
                passed = false
                detail = "\(error)"
            }
            out.append(Result(name: name, passed: passed, detail: detail, milliseconds: Date().timeIntervalSince(t0) * 1000))
        }
        return out
    }

    /// Plain-text report.
    package static func report(_ results: [Result]) -> String {
        let failed = results.filter { !$0.passed }.count
        var s = "ImageCrat \(BuildInfo.version) self-check — \(BuildInfo.platformDescription)\n"
        s += "Build: \(BuildInfo.buildDate)\n"
        s += failed == 0 ? "RESULT: PASS — all \(results.count) checks passed\n\n" : "RESULT: FAIL — \(failed) of \(results.count) checks failed\n\n"
        for r in results {
            s += "\(r.passed ? "PASS" : "FAIL")  \(r.name)  [\(String(format: "%.1f", r.milliseconds)) ms]\n"
            if !r.detail.isEmpty { s += "      \(r.detail)\n" }
        }
        return s
    }

    // MARK: The checks

    static let checks: [(String, () throws -> String)] = [
        ("Decode embedded PSD (8-bit RGB, RLE, groups)", embeddedPSD),
        ("Decode embedded PSD (16-bit grayscale, raw)", embeddedGray16),
        ("Decode embedded PNG (RGBA)", embeddedPNG),
        ("PSD write → read round trip (8/16-bit, raw/RLE, PSD/PSB)", psdRoundTrip),
        ("PSD layer pixels and thumbnails", psdLayers),
        ("PSD damaged-file handling (truncations)", psdDamaged),
        ("PNG encode → decode round trip", pngRoundTrip),
        ("Deflate / inflate and zip round trip", deflateZip),
        ("PackBits round trip", packBits),
        ("Layer style descriptor round trip", layerStyle),
        ("ABR brush file built in code", abrImport),
        ("GIMP .gbr brush", gbrImport),
        ("Procreate .brushset", procreateImport),
        ("Krita .kpp presets", kritaImport),
        ("ImageCrat .icbrushes archive", icbrushesImport),
        ("Inpaint (content-aware fill) on a tiny image", inpaint),
        ("Content-aware scale", contentAwareScale),
        ("File loader: dispatch and clear errors", loaderErrors),
    ]

    static func embeddedPSD() throws -> String {
        let f = try PSDFile(bytes: EmbeddedSamples.psdRGB)
        try expect(f.width == 24 && f.height == 16 && f.depth == 8 && f.colorMode == 3, "header \(f.width)×\(f.height) \(f.depth)-bit mode \(f.colorMode)")
        try expect(abs((f.resolution ?? 0) - 150) < 0.01, "resolution \(f.resolution ?? 0)")
        try expect(f.layers.map(\.name) == ["Shapes", "Red box", "Background"], "layer names \(f.layers.map(\.name))")
        try expect(f.layers.map(\.depth) == [0, 1, 0], "nesting \(f.layers.map(\.depth))")
        try expect(f.layers[0].kind == .group && f.layers[0].blendMode == .passThrough, "group kind/blend")
        try expect(abs(f.layers[1].opacity - 128.0 / 255) < 1e-9, "opacity \(f.layers[1].opacity)")
        guard let c = try f.composite() else { throw Failure("no composite") }
        for (x, y, r, g, b, a) in EmbeddedSamples.rgbExpected {
            let p = c.pixel(x, y)
            try expect(p == (r, g, b, a), "composite pixel (\(x),\(y)) = \(p), expected \((r, g, b, a))")
        }
        guard let box = f.layerImage(f.layers[1].recordIndex) else { throw Failure("no layer pixels") }
        try expect(box.width == 8 && box.height == 6 && box.pixel(3, 3) == (255, 0, 0, 255), "layer pixels")
        return "24×16, 3 layers, composite and layer pixels match"
    }

    static func embeddedGray16() throws -> String {
        let f = try PSDFile(bytes: EmbeddedSamples.psdGray16)
        try expect(f.depth == 16 && f.colorMode == 1, "header")
        guard let c = try f.composite() else { throw Failure("no composite") }
        for (x, y) in [(0, 0), (3, 5), (7, 7)] {
            let v16 = (8 * x + y) * 1000
            let v = UInt8((v16 + 128) / 257)
            try expect(c.pixel(x, y) == (v, v, v, 255), "pixel (\(x),\(y)) = \(c.pixel(x, y)), expected \(v)")
        }
        return "8×8 16-bit gray reduced to 8 bits correctly"
    }

    static func embeddedPNG() throws -> String {
        guard let img = PNGCodec.decodeImage(Data(EmbeddedSamples.png)) else { throw Failure("decode failed") }
        try expect(img.width == 6 && img.height == 4, "size")
        for (x, y) in [(0, 0), (2, 3), (5, 1)] {
            let i = (y * 6 + x) * 4
            let want: [UInt8] = [UInt8(x * 40), UInt8(y * 60), 200, x < 3 ? 255 : 100]
            try expect(Array(img.rgba[i..<(i + 4)]) == want, "pixel (\(x),\(y)) = \(Array(img.rgba[i..<(i + 4)]))")
        }
        return "6×4 RGBA, straight alpha preserved"
    }

    static func psdRoundTrip() throws -> String {
        var n = 0
        for depth in [8, 16] {
            for comp in [PSDSimpleWriter.Compression.raw, .rle] {
                for psb in [false, true] {
                    let card = SampleFiles.testCard(width: 37, height: 23, alpha: true)
                    let data = PSDSimpleWriter.write(width: 37, height: 23, layers: [.pixels("Card", at: IPoint(x: 0, y: 0), card)], composite: card,
                                                     depth: depth, compression: comp, compositeAlpha: true, psb: psb)
                    let f = try PSDFile(data: data)
                    try expect(f.isPSB == psb && f.depth == depth, "header")
                    guard let back = try f.composite() else { throw Failure("no composite") }
                    // alpha exact; colour exact where opaque, within rounding where partly transparent (matting on white)
                    for i in stride(from: 0, to: card.pixels.count, by: 4) {
                        let a = card.pixels[i + 3]
                        try expect(back.pixels[i + 3] == a, "alpha at \(i / 4)")
                        if a == 255 { try expect(back.pixels[i] == card.pixels[i] && back.pixels[i + 1] == card.pixels[i + 1], "colour at \(i / 4)") }
                        else if a > 40 { try expect(abs(Int(back.pixels[i]) - Int(card.pixels[i])) <= 255 / Int(a) + 2, "unmatted colour at \(i / 4)") }
                    }
                    n += 1
                }
            }
        }
        return "\(n) variants"
    }

    static func psdLayers() throws -> String {
        let f = try PSDFile(data: SampleFiles.layeredPSD())
        try expect(f.layers.count == 5, "layer count \(f.layers.count)")
        try expect(f.layers.map(\.name) == ["Title bars", "Decorations", "Bubbles (screen)", "Hidden red block", "Background"], "names")
        try expect(f.layers[0].effects.contains("Drop Shadow") && f.layers[0].effects.contains("Stroke"), "effects \(f.layers[0].effects)")
        try expect(f.layers[2].blendMode == .screen && !f.layers[3].isVisible, "blend / visibility")
        guard let t = f.layerThumbnail(f.layers[3].recordIndex, maxSide: 64) else { throw Failure("no thumbnail") }
        try expect(t.width == 64 && t.height == 40, "thumbnail size \(t.width)×\(t.height)")
        let p = t.pixel(Int(130.0 / 10), Int(260.0 / 10))
        try expect(p.0 == 255 && p.3 == 255, "thumbnail content \(p)")
        try expect(t.pixel(63, 0).3 == 0, "thumbnail transparency")
        return "5 layers; kinds, effects, thumbnails"
    }

    static func psdDamaged() throws -> String {
        let card = SampleFiles.testCard(width: 48, height: 30, alpha: true)
        let small = PSDSimpleWriter.write(width: 48, height: 30, layers: [
            .pixels("Card", at: IPoint(x: 0, y: 0), card), .group("G"), .pixels("Part", at: IPoint(x: 5, y: 5), SampleFiles.bubbles(width: 20, height: 20)), .groupEnd,
        ], composite: card, compositeAlpha: true)
        let bytes = [UInt8](small)
        var opened = 0, rejected = 0
        var cut = 0
        while cut < bytes.count {
            if let f = try? PSDFile(bytes: Array(bytes[0..<cut])) {
                opened += 1
                _ = try? f.composite()
                for l in f.layers.prefix(3) { _ = f.layerThumbnail(l.recordIndex, maxSide: 16) }
            } else { rejected += 1 }
            cut += cut < 300 ? 1 : 97
        }
        try expect(rejected > 0 && opened > 0, "opened \(opened), rejected \(rejected)")
        return "\(opened + rejected) truncated copies handled without crashing"
    }

    static func pngRoundTrip() throws -> String {
        let card = SampleFiles.bubbles(width: 64, height: 48)
        let png = PNGCodec.encode(card.pixelBuffer())
        guard let back = PNGCodec.decodeImage(png) else { throw Failure("decode failed") }
        try expect(back.width == 64 && back.height == 48, "size")
        var maxErr = 0
        for i in stride(from: 0, to: card.pixels.count, by: 4) {
            try expect(back.rgba[i + 3] == card.pixels[i + 3], "alpha at \(i / 4)")
            if card.pixels[i + 3] > 64 { for k in 0..<3 { maxErr = max(maxErr, abs(Int(back.rgba[i + k]) - Int(card.pixels[i + k]))) } }
        }
        try expect(maxErr <= 4, "colour error \(maxErr)")
        return "\(png.count) bytes, max colour error \(maxErr) (premultiplied storage)"
    }

    static func deflateZip() throws -> String {
        var input: [UInt8] = []
        for i in 0..<50_000 { input.append(UInt8((i * i / 7 + i / 13) & 0xFF)) }
        input += Array(repeating: 42, count: 20_000)
        let z = Deflate.zlibCompress(input)
        let back = try Inflate.zlibDecompress(bytes: z)
        try expect(back == input, "zlib round trip")
        var w = ZipWriter()
        w.add(name: "a/b.txt", data: Data("hello ImageCrat".utf8))
        w.add(name: "big.bin", data: Data(input))
        let zip = try ZipReader(data: w.finish())
        try expect(try zip.data(for: "a/b.txt") == Data("hello ImageCrat".utf8), "zip text entry")
        try expect(try zip.data(for: "big.bin") == Data(input), "zip binary entry")
        return "\(input.count) → \(z.count) bytes"
    }

    static func packBits() throws -> String {
        let row: [UInt8] = [7, 7, 7, 7, 7, 1, 2, 3, 3, 9] + Array(repeating: 200, count: 300) + (0..<140).map { UInt8($0 % 251) }
        let packed = row.withUnsafeBufferPointer { PackBits.encode($0) }
        var r = BinaryReader(Data(packed))
        var out = [UInt8](repeating: 0, count: row.count)
        try out.withUnsafeMutableBufferPointer { try PackBits.decode(&r, into: $0.baseAddress!, count: row.count, byteLength: packed.count) }
        try expect(out == row, "round trip")
        return "\(row.count) → \(packed.count) bytes"
    }

    static func layerStyle() throws -> String {
        var fx = LayerEffects()
        fx.dropShadow.enabled = true; fx.dropShadow.distance = 12; fx.dropShadow.color = RGBA(hex: "112233")!
        fx.outerGlow.enabled = true; fx.bevel.enabled = true; fx.bevel.size = 7
        guard let back = PSDLayerStyle.decode(PSDLayerStyle.encode(fx)) else { throw Failure("decode failed") }
        try expect(back.activeNames == fx.activeNames, "effects \(back.activeNames)")
        try expect(abs(back.dropShadow.distance - 12) < 1e-6 && back.dropShadow.color.hex == "112233", "drop shadow settings")
        return back.activeNames.joined(separator: ", ")
    }

    static func abrImport() throws -> String {
        let src = SampleFiles.brushSet()
        let data = SampleFiles.abr()
        let set = try BrushImport.load(data: data, fileName: "check.abr")
        try expect(set.brushes.map(\.name) == src.brushes.map(\.name), "names \(set.brushes.map(\.name))")
        try expect(set.patterns.count == 1, "pattern count \(set.patterns.count)")
        let tips = FileLoader.tipPreviews(set)
        try expect(tips.count == src.brushes.count && tips.allSatisfy { $0.image.width > 1 }, "tip previews")
        // tip pixels survive exactly
        if let k = set.brushes[0].tipKey, case .gray(let t)? = set.tips[k]?.frames.first, case .gray(let o)? = src.tips["tip-0"]?.frames.first {
            try expect(SampleFiles.tightBytes(t) == SampleFiles.tightBytes(o), "tip pixels")
        } else { throw Failure("first tip missing") }
        return "\(set.brushes.count) brushes (\(set.format)), \(data.count) bytes"
    }

    static func gbrImport() throws -> String {
        let set = try BrushImport.load(data: SampleFiles.gbr(3), fileName: "star.gbr")
        try expect(set.brushes.count == 1 && set.brushes[0].name == "Star", "brush \(set.brushes.map(\.name))")
        let t = FileLoader.tipPreviews(set)
        try expect(t.first.map { $0.image.width >= 48 } ?? false, "tip size")
        return set.format
    }

    static func procreateImport() throws -> String {
        let set = try BrushImport.load(data: SampleFiles.brushset(), fileName: "x.brushset")
        try expect(set.name == "ImageCrat Sample Set", "set name \(set.name)")
        try expect(set.brushes.count == 3, "brush count \(set.brushes.count)")
        try expect(FileLoader.tipPreviews(set).allSatisfy { $0.image.width == 64 }, "tip previews")
        return set.brushes.map(\.name).joined(separator: ", ")
    }

    static func kritaImport() throws -> String {
        let a = try BrushImport.load(data: SampleFiles.kpp(embeddedTip: false), fileName: "a.kpp")
        try expect(a.brushes.first?.name == "Sample Soft Ellipse" && a.brushes.first?.tipKey == nil, "auto brush")
        try expect(abs((a.brushes.first?.params.size ?? 0) - 36) < 1e-9, "diameter")
        let b = try BrushImport.load(data: SampleFiles.kpp(embeddedTip: true), fileName: "b.kpp")
        try expect(b.brushes.first?.name == "Sample Star Stamp" && b.brushes.first?.tipKey != nil, "embedded tip")
        try expect(FileLoader.tipPreviews(b).first?.image.width == 40, "embedded tip size")
        return "auto brush + embedded GBR tip"
    }

    static func icbrushesImport() throws -> String {
        let set = try BrushImport.load(data: SampleFiles.icbrushes(), fileName: "x.icbrushes")
        try expect(set.brushes.count == SampleFiles.brushSet().brushes.count, "brush count")
        return "\(set.brushes.count) brushes"
    }

    static func stripes() -> PixelBuffer {
        let b = PixelBuffer(width: 48, height: 32)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<32 {
            for x in 0..<48 {
                let o = y * b.bytesPerRow + x * 4
                p[o] = (x / 4) % 2 == 0 ? 220 : 40
                p[o + 1] = UInt8(x * 5)
                p[o + 2] = UInt8(y * 7)
                p[o + 3] = 255
            }
        }
        return b
    }

    static func inpaint() throws -> String {
        let img = stripes()
        let hole = PixelBuffer(width: 48, height: 32, format: .gray)
        let hp = hole.data.assumingMemoryBound(to: UInt8.self)
        for y in 12..<20 { for x in 20..<28 { hp[y * hole.bytesPerRow + x] = 255 } }
        let ip = img.data.assumingMemoryBound(to: UInt8.self)
        for y in 12..<20 { for x in 20..<28 { for c in 0..<4 { ip[y * img.bytesPerRow + x * 4 + c] = 0 } } }
        let a = Inpainter.inpaint(img, hole: hole)
        let b = Inpainter.inpaint(img, hole: hole)
        try expect(RGBA8Image(a) == RGBA8Image(b), "deterministic")
        var reds = Set<UInt8>()
        for y in 0..<32 {
            for x in 0..<48 {
                let inHole = (12..<20).contains(y) && (20..<28).contains(x)
                if inHole { try expect(a.alpha(x, y) == 255, "hole pixel (\(x),\(y)) filled"); reds.insert(a.pixel(x, y).0) }
                else { try expect(a.pixel(x, y) == img.pixel(x, y), "outside pixel (\(x),\(y)) unchanged") }
            }
        }
        try expect(reds.contains { $0 > 150 } && reds.contains { $0 < 100 }, "fill reuses both stripe colours")
        return "8×8 hole filled from the surroundings"
    }

    static func contentAwareScale() throws -> String {
        let img = stripes()
        let a = ContentAwareScale.scale(img, newWidth: 36, newHeight: 32)
        try expect(a.width == 36 && a.height == 32, "size \(a.width)×\(a.height)")
        try expect(a.opaqueBounds() == IRect(x: 0, y: 0, width: 36, height: 32), "fully opaque")
        return "48×32 → 36×32"
    }

    static func loaderErrors() throws -> String {
        let u = URL(fileURLWithPath: "x.txt")
        do { _ = try FileLoader.load(data: Data("hello".utf8), url: u, ext: "txt"); throw Failure("text accepted") } catch let e as LoadError {
            try expect(e.localizedDescription.contains(".txt"), "message")
        }
        do { _ = try FileLoader.load(data: Data("8BPS garbage".utf8), url: URL(fileURLWithPath: "x.psd"), ext: "psd"); throw Failure("garbage PSD accepted") } catch is LoadError {}
        do { _ = try FileLoader.load(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]), url: URL(fileURLWithPath: "x.png"), ext: "png"); throw Failure("broken PNG accepted") } catch is LoadError {}
        do { _ = try FileLoader.load(data: Data([0, 6, 0, 0, 0, 0]), url: URL(fileURLWithPath: "x.abr"), ext: "abr"); throw Failure("broken ABR accepted") } catch is LoadError {}
        let ok = try FileLoader.load(data: Data(EmbeddedSamples.psdRGB), url: URL(fileURLWithPath: "s.psd"), ext: "psd")
        try expect(ok.picture != nil, "embedded PSD through the loader")
        return "unsupported, damaged PSD/PNG/ABR rejected with messages"
    }
}
