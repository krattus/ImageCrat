import Foundation
import ImageCratCore

/// Synthetic test files made in code: brush files in every format the core reads, a layered PSD and a few PNGs.
/// Used by the self-check and by `imagecrat-cli make-samples` (no third-party content).
package enum SampleFiles {
    // MARK: Tips

    /// A gray w×h buffer from a coverage function (255 = paint).
    package static func grayTip(_ w: Int, _ h: Int, _ f: (Double, Double) -> Double) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h, format: .gray)
        let d = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                // normalised coordinates, -1…1
                let u = (Double(x) + 0.5) / Double(w) * 2 - 1, v = (Double(y) + 0.5) / Double(h) * 2 - 1
                d[y * b.bytesPerRow + x] = UInt8(max(0, min(255, (f(u, v) * 255).rounded())))
            }
        }
        b.markDirty()
        return b
    }

    package static func tightBytes(_ b: PixelBuffer) -> [UInt8] {
        let d = b.data.assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity(b.width * b.height)
        for y in 0..<b.height { for x in 0..<b.width { out.append(d[y * b.bytesPerRow + x]) } }
        return out
    }

    /// Deterministic pseudo-random numbers (xorshift).
    package struct Random {
        var s: UInt64
        package init(_ seed: UInt64) { s = seed == 0 ? 0x9E37_79B9 : seed }
        package mutating func next() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s % 1_000_000) / 1_000_000
        }
    }

    /// Named procedural tips: soft disc, hard disc, ring, star, splatter, grass, chalk.
    package static func tips(side: Int = 64) -> [(String, PixelBuffer)] {
        var out: [(String, PixelBuffer)] = []
        out.append(("Soft Round", grayTip(side, side) { u, v in let r = sqrt(u * u + v * v); return max(0, 1 - r) * max(0, 1 - r) * 1.6 }))
        out.append(("Hard Round", grayTip(side, side) { u, v in min(1, max(0, (0.92 - sqrt(u * u + v * v)) * 20)) }))
        out.append(("Ring", grayTip(side, side) { u, v in let r = sqrt(u * u + v * v); return r > 0.55 && r < 0.85 ? 1 : 0 }))
        out.append(("Star", grayTip(side, side) { u, v in
            let a = atan2(v, u), r = sqrt(u * u + v * v)
            let edge = 0.45 + 0.4 * pow(abs(cos(a * 2.5)), 3)
            return min(1, max(0, (edge - r) * 12))
        }))
        var rnd = Random(42)
        let dots = (0..<26).map { _ in (rnd.next() * 1.6 - 0.8, rnd.next() * 1.6 - 0.8, 0.04 + rnd.next() * 0.12) }
        out.append(("Splatter", grayTip(side, side) { u, v in
            var c = 0.0
            for (x, y, r) in dots { let d = sqrt((u - x) * (u - x) + (v - y) * (v - y)); c = max(c, min(1, max(0, (r - d) * 30))) }
            return c
        }))
        var rnd2 = Random(7)
        let blades = (0..<9).map { _ in (rnd2.next() * 1.2 - 0.6, rnd2.next() * 0.5 - 0.25, 0.4 + rnd2.next() * 0.55) }
        out.append(("Grass", grayTip(side, side) { u, v in
            var c = 0.0
            for (x0, lean, len) in blades {
                let t = (1 - v) / 2   // 0 at the bottom, 1 at the top
                guard t >= 0, t <= len else { continue }
                let x = x0 + lean * t * t * 2
                let w = 0.06 * (1 - t / len)
                c = max(c, min(1, max(0, (w - abs(u - x)) * 40)))
            }
            return c
        }))
        var rnd3 = Random(99)
        let grain = (0..<(side * side)).map { _ in rnd3.next() }
        out.append(("Chalk", grayTip(side, side) { u, v in
            let r = sqrt(u * u * 0.7 + v * v * 1.4)
            let x = min(side - 1, Int((u + 1) / 2 * Double(side))), y = min(side - 1, Int((v + 1) / 2 * Double(side)))
            return r < 0.9 && grain[y * side + x] > 0.35 ? 0.75 + grain[y * side + x] * 0.25 : 0
        }))
        return out
    }

    // MARK: Brush files

    /// A brush set with sampled tips (one per procedural tip), a computed round brush and a pattern.
    package static func brushSet(name: String = "ImageCrat Sample Brushes") -> ImportedBrushSet {
        var set = ImportedBrushSet(name: name, format: "synthetic")
        for (i, (n, tip)) in tips().enumerated() {
            let key = "tip-\(i)"
            set.tips[key] = ImportedTipImage(.gray(tip))
            var p = BrushParams(size: Double(tip.width), hardness: 1, spacing: 0.15 + Double(i) * 0.05, angle: Double(i * 15), roundness: 1)
            if n == "Splatter" { p.scatterEnabled = true; p.scatter = 0.6 }
            if n == "Chalk" { p.textureEnabled = true; p.texturePatternID = "paper" }
            set.brushes.append(ImportedBrush(name: n, folderPath: i < 3 ? ["Basics"] : ["Textured"], tipKey: key, params: p))
        }
        set.brushes.append(ImportedBrush(name: "Computed Round 30 px", tipKey: nil, params: BrushParams(size: 30, hardness: 0.5)))
        set.patterns = [ImportedPattern(id: "paper", name: "Paper", image: .gray(grayTip(32, 32) { u, v in 0.5 + 0.5 * sin(u * 9) * cos(v * 7) }))]
        return set
    }

    package static func abr() -> Data { ABRWriter.write(brushSet()).data }

    package static func gbr(_ index: Int = 0) -> Data {
        let all = tips(side: 48)
        let (n, t) = all[index % all.count]
        return GIMPBrushWriter.gbr(name: n, width: t.width, height: t.height, pixels: tightBytes(t), spacing: 20)
    }

    /// Procreate brush set: two brushes from the synthetic archives with procedural shape / grain PNGs.
    package static func brushset() -> Data {
        var w = ZipWriter()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>name</key><string>ImageCrat Sample Set</string>
        <key>brushes</key><array><string>U1</string><string>U2</string><string>U3</string></array></dict></plist>
        """
        w.add(name: "brushset.plist", data: Data(plist.utf8))
        let t = tips(side: 64)
        let grainy = Data(base64Encoded: ProcreateArchives.grainy) ?? Data()
        let ink = Data(base64Encoded: ProcreateArchives.ink) ?? Data()
        w.add(name: "U1/Brush.archive", data: grainy)
        w.add(name: "U1/Shape.png", data: PNGCodec.encode(t[6].1))
        w.add(name: "U1/Grain.png", data: PNGCodec.encode(grayTip(32, 32) { u, v in 0.5 + 0.5 * sin((u + v) * 12) }))
        w.add(name: "U2/Brush.archive", data: ink)
        w.add(name: "U2/Shape.png", data: PNGCodec.encode(t[1].1))
        w.add(name: "U3/Brush.archive", data: ink)
        w.add(name: "U3/Shape.png", data: PNGCodec.encode(t[3].1))
        return w.finish()
    }

    /// Krita preset: an auto brush (computed tip) or one with an embedded GBR tip.
    package static func kpp(embeddedTip: Bool) -> Data {
        let xml: String
        if embeddedTip {
            let t = tips(side: 40)[3].1
            let gbr = GIMPBrushWriter.gbr(name: "star", width: t.width, height: t.height, pixels: tightBytes(t), spacing: 25)
            xml = """
            <Preset paintopid="paintbrush" name="Sample Star Stamp">
             <param type="string" name="brush_definition"><![CDATA[<Brush type="gbr_brush" filename="star.gbr" spacing="0.25" angle="0" scale="1" BrushVersion="2"/>]]></param>
             <param type="string" name="OpacityValue"><![CDATA[0.9]]></param>
             <resources><resource type="brushes" name="star" filename="star.gbr" md5sum="00">
            \(gbr.base64EncodedString(options: .lineLength64Characters))
            </resource></resources>
            </Preset>
            """
        } else {
            let def = """
            <Brush useAutoSpacing="0" angle="0.5" spacing="0.1" randomness="0" BrushVersion="2" type="auto_brush" density="1">
             <MaskGenerator spikes="2" hfade="0.6" ratio="0.6" diameter="36" id="default" type="circle" antialiasEdges="1" vfade="0.6"/>
            </Brush>
            """
            xml = """
            <!DOCTYPE preset>
            <Preset paintopid="paintbrush" name="Sample Soft Ellipse">
             <param type="string" name="brush_definition"><![CDATA[\(def)]]></param>
             <param type="string" name="OpacityValue"><![CDATA[0.8]]></param>
            </Preset>
            """
        }
        // the preset's thumbnail: the tip, dark on white
        let thumb = RGBA8Image(width: 32, height: 32, pixels: (0..<(32 * 32)).flatMap { i -> [UInt8] in
            let x = i % 32, y = i / 32
            let d = Double((x - 16) * (x - 16) + (y - 16) * (y - 16)).squareRoot()
            let v: UInt8 = d < 12 ? 40 : 255
            return [v, v, v, 255]
        })
        return PNGCodec.encode(thumb.pixelBuffer(), text: [("version", "5.0"), ("preset", xml)], compressText: true)
    }

    package static func icbrushes() -> Data { BrushSetArchive.write(brushSet(name: "ImageCrat Archive")) }

    // MARK: Images

    /// RGBA test card: hue sweep, gray ramp and a transparent corner.
    package static func testCard(width w: Int = 512, height h: Int = 320, alpha: Bool = true) -> RGBA8Image {
        var img = RGBA8Image(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var r = 0.0, g = 0.0, b = 0.0
                if y < h * 2 / 3 {
                    let hue = Double(x) / Double(w) * 6
                    let k = Double(y) / Double(h * 2 / 3)
                    func ch(_ o: Double) -> Double { max(0, min(1, abs((hue + o).truncatingRemainder(dividingBy: 6) - 3) - 1)) }
                    r = ch(0) * (1 - k) + k * 0.5; g = ch(4) * (1 - k) + k * 0.5; b = ch(2) * (1 - k) + k * 0.5
                } else {
                    let v = min(1, Double(x * 16 / max(1, w)) / 15)
                    r = v; g = v; b = v
                }
                img.pixels[i] = u8(r * 255); img.pixels[i + 1] = u8(g * 255); img.pixels[i + 2] = u8(b * 255)
                var a = 255.0
                if alpha {
                    let dx = Double(w - x) / Double(w / 4), dy = Double(y) / Double(h / 3)
                    if dx < 1 && dy < 1 { a = 255 * max(dx, dy) }
                }
                img.pixels[i + 3] = u8(a)
            }
        }
        return img
    }

    /// Clamped, rounded conversion to a byte.
    package static func u8(_ v: Double) -> UInt8 { v.isNaN ? 0 : UInt8(max(0, min(255, v.rounded()))) }

    /// Soft coloured circles on transparency.
    package static func bubbles(width w: Int = 300, height h: Int = 300) -> RGBA8Image {
        var img = RGBA8Image(width: w, height: h)
        var rnd = Random(2026)
        let circles = (0..<14).map { _ -> (Double, Double, Double, Double, Double, Double) in
            let rad = 20 + rnd.next() * min(60, Double(min(w, h)) / 4)
            // keep every circle inside the image so none is cut off at the layer edge
            let cx = rad + 1 + rnd.next() * max(0, Double(w) - 2 * rad - 2), cy = rad + 1 + rnd.next() * max(0, Double(h) - 2 * rad - 2)
            return (cx, cy, rad, rnd.next(), rnd.next(), rnd.next())
        }
        for y in 0..<h {
            for x in 0..<w {
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                for (cx, cy, rad, cr, cg, cb) in circles {
                    let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
                    let cov = max(0, min(1, (rad - d) / 6)) * 0.7
                    guard cov > 0 else { continue }
                    // "over"
                    r = cr * cov + r * (1 - cov); g = cg * cov + g * (1 - cov); b = cb * cov + b * (1 - cov)
                    a = cov + a * (1 - cov)
                }
                let i = (y * w + x) * 4
                if a > 0 { img.pixels[i] = u8(r / a * 255); img.pixels[i + 1] = u8(g / a * 255); img.pixels[i + 2] = u8(b / a * 255) }
                img.pixels[i + 3] = u8(a * 255)
            }
        }
        return img
    }

    /// A layered PSD (groups, hidden layer, blend modes, opacity, a layer style) written by `PSDSimpleWriter`.
    package static func layeredPSD(depth: Int = 8, psb: Bool = false) -> Data {
        let w = 640, h = 400
        let bg = testCard(width: w, height: h, alpha: false)
        let bub = bubbles(width: 300, height: 300)
        var fx = LayerEffects()
        fx.dropShadow.enabled = true; fx.dropShadow.distance = 8; fx.dropShadow.size = 10
        fx.stroke.enabled = true; fx.stroke.size = 3
        var title = RGBA8Image(width: 260, height: 60)
        for y in 0..<60 { for x in 0..<260 {
            let i = (y * 260 + x) * 4
            let inBar = (x / 20) % 2 == 0 && y > 10 && y < 50
            title.pixels[i] = 255; title.pixels[i + 1] = 255; title.pixels[i + 2] = 255; title.pixels[i + 3] = inBar ? 255 : 0
        } }
        var hiddenLayer = RGBA8Image(width: 200, height: 120)
        for i in 0..<(200 * 120) { hiddenLayer.pixels[i * 4] = 255; hiddenLayer.pixels[i * 4 + 3] = 255 }
        let layers: [PSDSimpleWriter.Layer] = [
            .pixels("Title bars", at: IPoint(x: 40, y: 30), title, extraBlocks: [("lfx2", PSDLayerStyle.encode(fx))]),
            .group("Decorations"),
            .pixels("Bubbles (screen)", at: IPoint(x: 300, y: 60), bub, blend: .screen, opacity: 230),
            .pixels("Hidden red block", at: IPoint(x: 60, y: 200), hiddenLayer, hidden: true),
            .groupEnd,
            .pixels("Background", at: IPoint(x: 0, y: 0), bg),
        ]
        // the composite: background with the visible layers on top (simple "normal"/"screen" over)
        var comp = bg
        func blend(_ src: RGBA8Image, at ox: Int, _ oy: Int, opacity: Double, screen: Bool) {
            for y in 0..<src.height { for x in 0..<src.width {
                let cx = ox + x, cy = oy + y
                guard cx >= 0, cy >= 0, cx < w, cy < h else { continue }
                let s = (y * src.width + x) * 4, d = (cy * w + cx) * 4
                let a = Double(src.pixels[s + 3]) / 255 * opacity
                guard a > 0 else { continue }
                for k in 0..<3 {
                    let sv = Double(src.pixels[s + k]) / 255, dv = Double(comp.pixels[d + k]) / 255
                    let mixed = screen ? 1 - (1 - sv) * (1 - dv) : sv
                    comp.pixels[d + k] = u8((mixed * a + dv * (1 - a)) * 255)
                }
            } }
        }
        blend(bub, at: 300, 60, opacity: 230.0 / 255, screen: true)
        blend(title, at: 40, 30, opacity: 1, screen: false)
        return PSDSimpleWriter.write(width: w, height: h, layers: layers, composite: comp, depth: depth, compression: .rle,
                                     compositeAlpha: false, resolution: 144, psb: psb)
    }

    /// Writes every synthetic sample into `dir`; returns the file names.
    @discardableResult
    package static func writeAll(to dir: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [(String, Data)] = [
            ("Sample Brushes.abr", abr()),
            ("Sample Star.gbr", gbr(3)),
            ("Sample Grass.gbr", gbr(5)),
            ("Sample Set.brushset", brushset()),
            ("Sample Soft Ellipse.kpp", kpp(embeddedTip: false)),
            ("Sample Star Stamp.kpp", kpp(embeddedTip: true)),
            ("Sample Archive.icbrushes", icbrushes()),
            ("Synthetic layered 8-bit.psd", layeredPSD()),
            ("Synthetic layered 16-bit.psd", layeredPSD(depth: 16)),
            ("Synthetic layered.psb", layeredPSD(psb: true)),
            ("Test card (transparent corner).png", PNGCodec.encode(testCard().pixelBuffer())),
            ("Bubbles (transparent).png", PNGCodec.encode(bubbles().pixelBuffer())),
            ("Embedded self-check sample.psd", Data(EmbeddedSamples.psdRGB)),
        ]
        files.append(("Not an image.txt", Data("This file is here to show the error message for unsupported files.\n".utf8)))
        for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
        return files.map(\.0)
    }
}
