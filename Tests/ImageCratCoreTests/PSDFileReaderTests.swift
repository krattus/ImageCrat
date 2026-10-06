import Foundation
import XCTest
import ImageCratCore

/// The portable PSD structure reader (`PSDFile`) and the minimal writer (`PSDSimpleWriter`): composites in every
/// supported depth / compression, the layer tree, layer pixels and thumbnails, and damaged files.
final class PSDFileReaderTests: XCTestCase {
    /// w×h straight RGBA gradient; `alpha` gives the coverage per pixel.
    private func gradient(_ w: Int, _ h: Int, alpha: (Int, Int) -> UInt8 = { _, _ in 255 }) -> RGBA8Image {
        var img = RGBA8Image(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                img.pixels[i] = UInt8(x * 255 / max(1, w - 1))
                img.pixels[i + 1] = UInt8(y * 255 / max(1, h - 1))
                img.pixels[i + 2] = UInt8((x + y) * 7 & 255)
                img.pixels[i + 3] = alpha(x, y)
            }
        }
        return img
    }

    private func solid(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> RGBA8Image {
        var img = RGBA8Image(width: w, height: h)
        for i in 0..<(w * h) { img.pixels[i * 4] = r; img.pixels[i * 4 + 1] = g; img.pixels[i * 4 + 2] = b; img.pixels[i * 4 + 3] = a }
        return img
    }

    private func layeredDocument(depth: Int = 8, compression: PSDSimpleWriter.Compression = .rle, psb: Bool = false,
                                 mode: PSDSimpleWriter.Mode = .rgb, compositeAlpha: Bool = false) -> (Data, RGBA8Image) {
        let comp = gradient(40, 30, alpha: compositeAlpha ? { x, _ in x < 10 ? 0 : (x < 20 ? 128 : 255) } : { _, _ in 255 })
        var fx = LayerEffects()
        fx.dropShadow.enabled = true; fx.stroke.enabled = true
        let layers: [PSDSimpleWriter.Layer] = [
            .pixels("Top ✓", at: IPoint(x: 5, y: 4), solid(10, 8, 200, 30, 40, 128), blend: .multiply, opacity: 191,
                    extraBlocks: [("lfx2", PSDLayerStyle.encode(fx))]),
            .group("Folder"),
            .pixels("Inside", at: IPoint(x: 0, y: 0), solid(6, 6, 0, 0, 255), hidden: true),
            .group("Nested", open: false),
            .pixels("Deep", at: IPoint(x: 30, y: 20), solid(10, 10, 10, 250, 10), clipped: true),
            .groupEnd,
            .groupEnd,
            .pixels("Background", at: IPoint(x: 0, y: 0), gradient(40, 30)),
        ]
        let data = PSDSimpleWriter.write(width: 40, height: 30, layers: layers, composite: comp, mode: mode, depth: depth,
                                         compression: compression, compositeAlpha: compositeAlpha, resolution: 300, psb: psb)
        return (data, comp)
    }

    func testCompositeAllDepthsAndCompressions() throws {
        for depth in [8, 16] {
            for compression in [PSDSimpleWriter.Compression.raw, .rle] {
                for psb in [false, true] {
                    let (data, comp) = layeredDocument(depth: depth, compression: compression, psb: psb)
                    let f = try PSDFile(data: data)
                    XCTAssertEqual(f.width, 40); XCTAssertEqual(f.height, 30); XCTAssertEqual(f.depth, depth)
                    XCTAssertEqual(f.isPSB, psb)
                    XCTAssertEqual(f.resolution ?? 0, 300, accuracy: 0.01)
                    XCTAssertTrue(f.warnings.isEmpty, "\(f.warnings)")
                    let img = try XCTUnwrap(try f.composite())
                    XCTAssertEqual(img, comp, "depth \(depth) \(compression) psb \(psb)")
                }
            }
        }
    }

    func testCompositeTransparencyIsUnmatted() throws {
        let (data, comp) = layeredDocument(compositeAlpha: true)
        let f = try PSDFile(data: data)
        XCTAssertTrue(f.compositeHasTransparency)
        let img = try XCTUnwrap(try f.composite())
        for y in 0..<30 {
            for x in 0..<40 {
                let a = img.pixel(x, y), b = comp.pixel(x, y)
                XCTAssertEqual(a.3, b.3)
                if b.3 == 255 { XCTAssertTrue(a == b) }
                if b.3 == 128 { XCTAssertLessThanOrEqual(abs(Int(a.0) - Int(b.0)), 2, "unmatted colour at \(x),\(y)") }
            }
        }
    }

    func testGrayscale() throws {
        let (data, comp) = layeredDocument(depth: 16, mode: .grayscale)
        let f = try PSDFile(data: data)
        XCTAssertEqual(f.colorMode, 1)
        let img = try XCTUnwrap(try f.composite())
        let p = img.pixel(17, 9)
        XCTAssertEqual(p.0, p.1); XCTAssertEqual(p.1, p.2)
        XCTAssertEqual(p.0, PSDSimpleWriter.luma(comp.pixels, 9 * 40 + 17))
    }

    func testLayerTree() throws {
        let (data, _) = layeredDocument()
        let f = try PSDFile(data: data)
        XCTAssertEqual(f.layers.map(\.name), ["Top ✓", "Folder", "Inside", "Nested", "Deep", "Background"])
        XCTAssertEqual(f.layers.map(\.depth), [0, 0, 1, 1, 2, 0])
        XCTAssertEqual(f.layers.map(\.kind), [.pixel, .group, .pixel, .group, .pixel, .pixel])
        let top = f.layers[0]
        XCTAssertEqual(top.blendMode, .multiply)
        XCTAssertEqual(top.opacity, 191.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(Set(top.effects), ["Drop Shadow", "Stroke"])
        XCTAssertEqual(top.rect, IRect(x: 5, y: 4, width: 10, height: 8))
        XCTAssertFalse(f.layers[2].isVisible)
        XCTAssertTrue(f.layers[4].isClipped)
        XCTAssertEqual(f.layers[1].blendMode, .passThrough)
        XCTAssertEqual(f.layers[3].kindDetail, "closed")
        let text = f.describe(fileName: "x.psd")
        XCTAssertTrue(text.contains("40 × 30 px") && text.contains("  [-] Inside") && text.contains("fx: "))
    }

    func testLayerPixelsAndThumbnails() throws {
        let (data, _) = layeredDocument(depth: 16)
        let f = try PSDFile(data: data)
        let top = f.layers[0]
        let img = try XCTUnwrap(f.layerImage(top.recordIndex))
        XCTAssertEqual(img.width, 10); XCTAssertEqual(img.height, 8)
        XCTAssertTrue(img.pixel(3, 3) == (200, 30, 40, 128))
        XCTAssertNil(f.layerImage(f.layers[1].recordIndex), "groups have no pixels")
        // thumbnail: canvas aspect, the layer in place, transparent elsewhere
        let t = try XCTUnwrap(f.layerThumbnail(f.layers[4].recordIndex, maxSide: 20))
        XCTAssertEqual(t.width, 20); XCTAssertEqual(t.height, 15)
        XCTAssertEqual(t.pixel(0, 0).3, 0)
        XCTAssertTrue(t.pixel(17, 12) == (10, 250, 10, 255))
    }

    func testRGBA8ImageConversions() {
        let img = gradient(9, 7) { x, _ in UInt8(x * 30) }
        let back = RGBA8Image(img.pixelBuffer())
        for y in 0..<7 {
            for x in 0..<9 {
                let a = img.pixel(x, y), b = back.pixel(x, y)
                XCTAssertEqual(a.3, b.3)
                if a.3 > 60 { XCTAssertLessThanOrEqual(abs(Int(a.0) - Int(b.0)), 2) }
            }
        }
        let small = gradient(100, 50).downscaled(maxSide: 10)
        XCTAssertEqual(small.width, 10); XCTAssertEqual(small.height, 5)
        XCTAssertTrue(small.isOpaque)
    }

    func testRejectsNonPSDAndDamagedFilesNeverCrash() throws {
        XCTAssertThrowsError(try PSDFile(data: Data("hello world, not a psd at all".utf8)))
        XCTAssertThrowsError(try PSDFile(data: Data()))
        let (data, _) = layeredDocument(compositeAlpha: true)
        let bytes = [UInt8](data)
        // every truncation point in the first part, then coarser
        var cut = 0
        while cut < bytes.count {
            if let f = try? PSDFile(bytes: Array(bytes[0..<cut])) {
                _ = try? f.composite()
                for l in f.layers { _ = f.layerThumbnail(l.recordIndex, maxSide: 16) }
                _ = f.describe()
            }
            cut += cut < 400 ? 1 : 37
        }
        // random overwrites (deterministic)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        for _ in 0..<300 {
            var b = bytes
            for _ in 0..<(1 + Int(next() % 6)) { b[Int(next() % UInt64(b.count))] = UInt8(truncatingIfNeeded: next()) }
            if let f = try? PSDFile(bytes: b) {
                _ = try? f.composite()
                for l in f.layers { _ = f.layerImage(l.recordIndex) }
            }
        }
    }
}
