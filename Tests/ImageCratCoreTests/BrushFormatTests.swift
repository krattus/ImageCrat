import XCTest
@testable import ImageCratCore

/// Brush file formats in the portable core: inflate / deflate, zip, PNG, property lists, GIMP, Procreate, Krita,
/// ImageCrat's own brush-set archive, the coverage rule and the format sniffer. All inputs are synthesised in code or
/// embedded as literals (BrushFormatVectors.swift, generated once with python3's zlib / zipfile and plutil).
final class BrushFormatTests: XCTestCase {

    // MARK: - Helpers

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    }

    /// Feeds damaged variants of `data` to `body`: truncations, random byte overwrites, and 0xFFFFFFFF length fields.
    /// The only assertion is that nothing crashes (throwing / returning partial results is fine).
    private func fuzz(_ data: Data, seed: UInt64, iterations: Int = 300, _ body: (Data) -> Void) {
        let bytes = [UInt8](data)
        let n = bytes.count
        // (a) truncation: every length for small inputs, ~200 cut points otherwise
        let step = max(1, n / 200)
        var cut = 0
        while cut < n { body(Data(bytes[0..<cut])); cut += step }
        // (b) random overwrites
        var rng = SplitMix64(state: seed)
        for _ in 0..<iterations {
            var b = bytes
            let k = 1 + rng.int(8)
            for _ in 0..<k where !b.isEmpty { b[rng.int(b.count)] = UInt8(truncatingIfNeeded: rng.next()) }
            body(Data(b))
        }
        // (c) length-like fields set to 0xFFFFFFFF (all offsets in the first 96 bytes, then random ones)
        var offsets = Array(0..<min(96, max(0, n - 3)))
        for _ in 0..<64 where n > 4 { offsets.append(rng.int(n - 3)) }
        for o in offsets {
            var b = bytes
            for i in 0..<4 { b[o + i] = 0xFF }
            body(Data(b))
        }
    }

    private func grayBuffer(_ w: Int, _ h: Int, _ f: (Int, Int) -> UInt8) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h, format: .gray)
        let d = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { d[y * b.bytesPerRow + x] = f(x, y) } }
        b.markDirty()
        return b
    }

    /// Premultiplied RGBA buffer from straight colours.
    private func rgbaBuffer(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h, format: .rgba)
        let d = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, bl, a) = f(x, y)
                let o = y * b.bytesPerRow + x * 4
                d[o] = UInt8((Int(r) * Int(a) + 127) / 255); d[o + 1] = UInt8((Int(g) * Int(a) + 127) / 255)
                d[o + 2] = UInt8((Int(bl) * Int(a) + 127) / 255); d[o + 3] = a
            }
        }
        b.markDirty()
        return b
    }

    private func gray(_ b: PixelBuffer, _ x: Int, _ y: Int) -> UInt8 {
        b.data.assumingMemoryBound(to: UInt8.self)[y * b.bytesPerRow + x * b.bytesPerPixel]
    }

    private func grayImage(_ d: BrushImageData?, file: StaticString = #filePath, line: UInt = #line) -> PixelBuffer? {
        guard case .gray(let b)? = d else { XCTFail("expected a gray image", file: file, line: line); return nil }
        return b
    }

    private func discTip(_ side: Int) -> PixelBuffer {
        grayBuffer(side, side) { x, y in
            let dx = Double(x) - Double(side - 1) / 2, dy = Double(y) - Double(side - 1) / 2
            return dx * dx + dy * dy <= Double(side * side) / 9 ? 255 : 0
        }
    }

    // MARK: - Checksums, inflate, deflate

    func testChecksums() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(Adler32.checksum(Array("Wikipedia".utf8)), 0x11E6_0398)
        XCTAssertEqual(CRC32.checksum([UInt8]()), 0)
        XCTAssertEqual(Adler32.checksum([UInt8]()), 1)
    }

    func testInflateVectors() throws {
        let payload = BrushFormatVectors.inflatePayload
        let V = BrushFormatVectors.self
        XCTAssertEqual(try Inflate.zlibDecompress(bytes: [UInt8](V.bytes(V.zlibStored))), payload)
        XCTAssertEqual(try Inflate.zlibDecompress(bytes: [UInt8](V.bytes(V.zlibDefault))), payload)
        XCTAssertEqual(try Inflate.inflateRaw(bytes: [UInt8](V.bytes(V.rawFixed))), payload)
        XCTAssertEqual(try Inflate.inflateRaw(bytes: [UInt8](V.bytes(V.rawDynamic))), payload)
        XCTAssertEqual(try Inflate.inflateRaw(bytes: [UInt8](V.bytes(V.rawMultiBlock))), payload)
        XCTAssertEqual(try Inflate.zlibDecompress(V.bytes(V.zlibDefault)), Data(payload))
        // consumed count stops at the end of the stream
        var trailing = [UInt8](V.bytes(V.rawDynamic)); let streamLen = trailing.count
        trailing += [1, 2, 3]
        let r = trailing.withUnsafeBytes { Inflate.inflateRawPartial($0) }
        XCTAssertNil(r.error)
        XCTAssertEqual(r.consumed, streamLen)
    }

    func testInflateLimitsAndErrors() {
        let V = BrushFormatVectors.self
        let z = [UInt8](V.bytes(V.zlibDefault))
        XCTAssertThrowsError(try Inflate.zlibDecompress(bytes: z, maxOutput: 1000))
        let partial = z.withUnsafeBytes { Inflate.zlibDecompressPartial($0, maxOutput: 1000, stopAtLimit: true) }
        XCTAssertNil(partial.error)
        XCTAssertEqual(partial.output, Array(BrushFormatVectors.inflatePayload.prefix(1000)))
        XCTAssertThrowsError(try Inflate.zlibDecompress(bytes: [0x78]))
        XCTAssertThrowsError(try Inflate.zlibDecompress(bytes: [0x78, 0x9C]))
        XCTAssertThrowsError(try Inflate.zlibDecompress(bytes: Array(z.prefix(z.count / 2))))
        var bad = z; bad[bad.count - 1] ^= 0xFF
        XCTAssertThrowsError(try Inflate.zlibDecompress(bytes: bad))                      // checksum
        XCTAssertNoThrow(try Inflate.zlibDecompress(bytes: bad, verifyChecksum: false))
        XCTAssertThrowsError(try Inflate.inflateRaw(bytes: [0x07]))                         // block type 3
    }

    func testDeflateRoundTrip() throws {
        var rng = SplitMix64(state: 7)
        var inputs: [[UInt8]] = [[], [42], BrushFormatVectors.inflatePayload, [UInt8](repeating: 9, count: 100_000)]
        inputs.append((0..<20_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        inputs.append((0..<50_000).map { (i: Int) -> UInt8 in
            let base: Int = (i / 7) % 13
            return UInt8(base + (i % 300 == 0 ? 100 : 0))
        })
        for input in inputs {
            let raw = Deflate.compress(input)
            XCTAssertEqual(try Inflate.inflateRaw(bytes: raw), input)
            let z = Deflate.zlibCompress(input)
            XCTAssertEqual(try Inflate.zlibDecompress(bytes: z), input)
            XCTAssertEqual(try Inflate.inflateRaw(bytes: Deflate.stored(input)), input)
        }
        XCTAssertLessThan(Deflate.compress([UInt8](repeating: 9, count: 100_000)).count, 2_000)
        XCTAssertLessThan(Deflate.compress(BrushFormatVectors.inflatePayload).count, BrushFormatVectors.inflatePayload.count / 2)
    }

    // MARK: - Zip

    func testZipReadsPythonArchive() throws {
        let zip = try ZipReader(data: BrushFormatVectors.bytes(BrushFormatVectors.zipDeflated))
        XCTAssertEqual(zip.entries.map(\.name), ["a.txt", "dir/B.bin", "c.txt"])   // directory entry not listed
        XCTAssertEqual([UInt8](try zip.data(for: "a.txt")), BrushFormatVectors.inflatePayload)
        XCTAssertEqual([UInt8](try zip.data(for: "DIR/b.BIN")), Array((0..<20).flatMap { _ in 0..<256 }.map { UInt8($0) }))
        XCTAssertEqual(String(decoding: try zip.data(for: "c.txt"), as: UTF8.self), "stored entry")
        XCTAssertEqual(zip.entry(named: "dir/B.bin")?.directory, "dir")
        XCTAssertEqual(zip.entry(named: "dir/B.bin")?.fileName, "B.bin")
        XCTAssertThrowsError(try zip.data(for: "missing"))
    }

    func testZipDataDescriptors() throws {
        let zip = try ZipReader(data: BrushFormatVectors.bytes(BrushFormatVectors.zipDataDescriptor))
        XCTAssertEqual(zip.entries.count, 2)
        XCTAssertTrue(zip.entries.allSatisfy { $0.flags & 8 != 0 })
        XCTAssertEqual([UInt8](try zip.data(for: "streamed.txt")), BrushFormatVectors.inflatePayload)
        XCTAssertEqual(String(decoding: try zip.data(for: "x/y.txt"), as: UTF8.self), "hello hello hello hello")
    }

    func testZipWriterRoundTrip() throws {
        var w = ZipWriter()
        w.add(name: "manifest.json", data: Data("{}".utf8))
        w.add(name: "tips/ä ü.png", data: Data((0..<1000).map { UInt8($0 % 251) }))
        w.add(name: "empty.bin", data: Data())
        w.add(name: "manifest.json", data: Data("dup".utf8))   // ignored
        let data = w.finish()
        let zip = try ZipReader(data: data)
        XCTAssertEqual(zip.entries.map(\.name), ["manifest.json", "tips/ä ü.png", "empty.bin"])
        XCTAssertEqual(try zip.data(for: "manifest.json"), Data("{}".utf8))
        XCTAssertEqual(try zip.data(for: "tips/ä ü.png"), Data((0..<1000).map { UInt8($0 % 251) }))
        XCTAssertEqual(try zip.data(for: "empty.bin"), Data())
        // Optional external check: BRUSH_ZIP_DUMP=/path/x.zip swift test → `unzip -t` / `ditto -x -k` the file.
        if let path = ProcessInfo.processInfo.environment["BRUSH_ZIP_DUMP"] {
            try data.write(to: URL(fileURLWithPath: path))
            try BrushSetArchive.write(sampleSet()).write(to: URL(fileURLWithPath: path + ".icbrushes"))
        }
        // Prepended data (self-extractor style) shifts all offsets; the reader compensates.
        let shifted = try ZipReader(data: Data([UInt8](repeating: 0x55, count: 37)) + data)
        XCTAssertEqual(try shifted.data(for: "manifest.json"), Data("{}".utf8))
        // An archive comment is skipped when searching for the end record.
        var commented = [UInt8](data)
        commented[commented.count - 2] = 5
        commented += Array("hello".utf8)
        XCTAssertEqual(try ZipReader(data: Data(commented)).entries.count, 3)
    }

    func testZipRejectsEncryptedAndBombs() throws {
        var w = ZipWriter()
        w.add(name: "secret.txt", data: Data("x".utf8))
        var b = [UInt8](w.finish())
        b[6] |= 1                                             // local header flags
        let cd = b.count - 22 - 46 - "secret.txt".utf8.count  // central header start
        b[cd + 8] |= 1
        let zip = try ZipReader(data: Data(b))
        XCTAssertTrue(zip.entries[0].isEncrypted)
        XCTAssertThrowsError(try zip.data(for: "secret.txt"))
        // Declared size beyond the per-entry cap is refused before inflating.
        var big = [UInt8](BrushFormatVectors.bytes(BrushFormatVectors.zipDeflated))
        let z = try ZipReader(data: Data(big))
        let e = z.entry(named: "a.txt")!
        var q = 0
        // central directory header of "a.txt" (the first one belongs to the "dir/" directory entry)
        while !(big[q] == 0x50 && big[q + 1] == 0x4B && big[q + 2] == 1 && big[q + 3] == 2
                && Array(big[(q + 46)..<(q + 51)]) == Array("a.txt".utf8)) { q += 1 }
        XCTAssertEqual(e.name, "a.txt")
        big.replaceSubrange((q + 24)..<(q + 28), with: [0xFF, 0xFF, 0xFF, 0x7F])
        let z2 = try ZipReader(data: Data(big))
        XCTAssertThrowsError(try z2.data(for: "a.txt"))
    }

    // MARK: - PNG

    func testPNGDecodeAllColourTypes() {
        for (name, w, h, png, expected) in BrushFormatVectors.pngCases {
            guard let img = PNGCodec.decodeImage(BrushFormatVectors.bytes(png)) else { XCTFail("\(name) did not decode"); continue }
            XCTAssertEqual(img.width, w, name)
            XCTAssertEqual(img.height, h, name)
            let exp = [UInt8](BrushFormatVectors.bytes(expected))
            if img.rgba != exp {
                let i = zip(img.rgba, exp).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                XCTFail("\(name): first difference at byte \(i) (pixel \(i / 4))")
            }
            XCTAssertEqual(img.isGrayscale, name.hasPrefix("g"), name)
        }
    }

    func testPNGPremultipliedAndGrayscaleDecode() {
        let cases = Dictionary(uniqueKeysWithValues: BrushFormatVectors.pngCases.map { ($0.0, $0) })
        let ga = BrushFormatVectors.bytes(cases["ga8"]!.3)
        let buf = PNGCodec.decode(ga)!
        let img = PNGCodec.decodeImage(ga)!
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        let a = Int(img.rgba[3 * 4 + 3]), g = Int(img.rgba[3 * 4])
        XCTAssertEqual(Int(p[3 * 4]), (g * a + 127) / 255)
        XCTAssertEqual(Int(p[3 * 4 + 3]), a)
        XCTAssertNil(PNGCodec.decodeGrayscale(ga))                      // has real alpha
        let g8 = PNGCodec.decodeGrayscale(BrushFormatVectors.bytes(cases["g8"]!.3))!
        XCTAssertEqual(g8.format, .gray)
        let expectedG8: Int = (5 * 37 + 4 * 91 + 5 * 4 * 7) % 256
        XCTAssertEqual(Int(gray(g8, 5, 4)), expectedG8)
        XCTAssertNil(PNGCodec.decodeGrayscale(BrushFormatVectors.bytes(cases["rgb8"]!.3)))
    }

    func testPNGEncodeRoundTrip() {
        let g = grayBuffer(37, 23) { x, y in UInt8((x * 7 + y * 13) % 256) }
        let gd = PNGCodec.encode(g)
        let g2 = PNGCodec.decodeGrayscale(gd)!
        for y in 0..<23 { for x in 0..<37 { XCTAssertEqual(gray(g2, x, y), gray(g, x, y)) } }
        let c = rgbaBuffer(19, 17) { x, y in (UInt8(x * 13), UInt8(y * 15), UInt8((x + y) * 5), UInt8((x * y * 3) % 256)) }
        let c2 = PNGCodec.decode(PNGCodec.encode(c))!
        let s = c.data.assumingMemoryBound(to: UInt8.self), d = c2.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<17 {
            for x in 0..<19 {
                for k in 0..<4 {
                    let a = Int(s[y * c.bytesPerRow + x * 4 + k]), b = Int(d[y * c2.bytesPerRow + x * 4 + k])
                    XCTAssertLessThanOrEqual(abs(a - b), 1, "pixel \(x),\(y) channel \(k)")
                }
            }
        }
        // A large flat tip compresses well.
        XCTAssertLessThan(PNGCodec.encode(discTip(256)).count, 6000)
    }

    func testPNGTextChunksAndLimits() {
        let t = PNGCodec.textChunks(BrushFormatVectors.bytes(BrushFormatVectors.pngText))
        XCTAssertEqual(t["Title"], "Hello PNG")
        XCTAssertEqual(t["preset"], "<Preset name=\"zipped\"/>")
        XCTAssertEqual(t["Desc"], "Ünïcødé ✓")
        XCTAssertEqual(t["Plain"], "plain ü")
        // encoder text round trip (tEXt, zTXt, iTXt)
        let img = grayBuffer(2, 2) { _, _ in 1 }
        for compress in [false, true] {
            let png = PNGCodec.encode(img, text: [("a", "latin é"), ("b", "unicode ✓")], compressText: compress)
            let tt = PNGCodec.textChunks(png)
            XCTAssertEqual(tt["a"], "latin é")
            XCTAssertEqual(tt["b"], "unicode ✓")
        }
        // oversized header
        var png = [UInt8](PNGCodec.encode(img))
        png[16] = 0x00; png[17] = 0x01; png[18] = 0x00; png[19] = 0x00     // width 65536
        XCTAssertNil(PNGCodec.decode(Data(png)))
        XCTAssertNil(PNGCodec.decode(Data([1, 2, 3])))
        XCTAssertEqual(PNGCodec.header(PNGCodec.encode(img))?.width, 2)
    }

    // MARK: - Property lists

    func testBinaryPlistMatchesXML() throws {
        let bin = try BinaryPlist.parse(BrushFormatVectors.bytes(BrushFormatVectors.bplistGeneral))
        XCTAssertEqual(bin["name"]?.string, "Brush Set")
        XCTAssertEqual(bin["unicode"]?.string, "Pinsel ✓ ü")
        XCTAssertEqual(bin["small"], .int(42))
        XCTAssertEqual(bin["big"], .int(-1_234_567_890_123))
        XCTAssertEqual(bin["real"], .real(0.375))
        XCTAssertEqual(bin["yes"], .bool(true))
        XCTAssertEqual(bin["no"], .bool(false))
        XCTAssertEqual(bin["blob"], .data(Data([0, 1, 2, 255])))
        XCTAssertEqual(bin["when"], .date(599_529_600))   // 2020-01-01 UTC
        XCTAssertEqual(bin["brushes"]?.array?.compactMap(\.string), ["A", "B", "C"])
        XCTAssertEqual(bin["nested"]?["inner"], .array([.int(1), .real(2.5)]))
        let xml = try BinaryPlist.parse(Data(BrushFormatVectors.xmlPlistGeneral.utf8))
        XCTAssertEqual(xml, bin)
    }

    func testKeyedArchiverResolution() throws {
        let root = try XCTUnwrap(BinaryPlist.unarchiveRoot(BrushFormatVectors.bytes(BrushFormatVectors.archiveGrainy)))
        XCTAssertEqual(root["$classname"]?.string, "SilicaBrush")
        XCTAssertEqual(root["name"]?.string, "Grainy Pencil")
        XCTAssertEqual(root["paintSize"]?.double, 0.1)
        XCTAssertEqual(root["shapeFlipXJitter"]?.bool, true)
        XCTAssertEqual(root["extras"]?["k"], .array([.int(1), .string("two")]))
        XCTAssertEqual(root["extras"]?["data"], .data(Data([1, 2, 3])))
        XCTAssertEqual(root["created"], .date(1000))
        XCTAssertEqual(root["selfRef"], .null)   // reference cycle cut
        // the raw archive keeps UIDs
        let raw = try BinaryPlist.parse(BrushFormatVectors.bytes(BrushFormatVectors.archiveGrainy))
        guard case .uid? = raw["$top"]?["root"] else { return XCTFail("expected a UID") }
        XCTAssertNil(BinaryPlist.unarchive(.dict([:])))
    }

    func testBinaryPlistRejectsCycles() {
        // object 0: array containing itself
        var b = Array("bplist00".utf8)
        b += [0xA1, 0x00]                       // array, 1 ref → 0
        let table = b.count
        b += [0x08]                             // offset of object 0
        b += [0, 0, 0, 0, 0, 0, 1, 1]           // trailer: offset size 1, ref size 1
        b += [0, 0, 0, 0, 0, 0, 0, 1]           // 1 object
        b += [0, 0, 0, 0, 0, 0, 0, 0]           // top = 0
        b += [0, 0, 0, 0, 0, 0, 0, UInt8(table)]
        XCTAssertThrowsError(try BinaryPlist.parseBinary(Data(b)))
        // a keyed archive whose objects reference each other in a loop resolves without hanging
        let loop: PlistValue = .dict([
            "$top": .dict(["root": .uid(1)]),
            "$objects": .array([.string("$null"), .dict(["next": .uid(2)]), .dict(["next": .uid(1)])]),
        ])
        let r = BinaryPlist.unarchive(loop)
        XCTAssertEqual(r?["root"]?["next"]?["next"], .null)
    }

    // MARK: - GIMP

    func testGBRGray() throws {
        let px: [UInt8] = (0..<15).map { UInt8($0 * 17) }
        let data = GIMPBrushWriter.gbr(name: "Tiny", width: 5, height: 3, pixels: px, spacing: 40)
        XCTAssertTrue(GIMPBrush.isGBR(data))
        let set = try GIMPBrush.readGBR(data: data, name: "file")
        XCTAssertEqual(set.brushes.count, 1)
        let b = set.brushes[0]
        XCTAssertEqual(b.name, "Tiny")
        XCTAssertEqual(b.params.size, 5)
        XCTAssertEqual(b.params.spacing, 0.4, accuracy: 1e-9)
        let tip = try XCTUnwrap(grayImage(set.tips[b.tipKey!]?.frames.first))
        XCTAssertEqual(tip.width, 5); XCTAssertEqual(tip.height, 5)
        XCTAssertEqual(gray(tip, 0, 0), 0)                   // padding row
        XCTAssertEqual(gray(tip, 0, 1), 0)                   // first pixel (value 0)
        XCTAssertEqual(gray(tip, 4, 3), 14 * 17)             // last pixel, 255 = paint stays 255-based
        XCTAssertEqual(gray(tip, 2, 2), 7 * 17)
    }

    func testGBRPixmapVersion1AndFloat() throws {
        // RGBA pixmap with transparency → alpha is the mask
        var rgba = [UInt8]()
        for i in 0..<4 { rgba += [200, 10, 10, UInt8(i * 80)] }
        let set = try GIMPBrush.readGBR(data: GIMPBrushWriter.gbr(name: "Pix", width: 2, height: 2, pixels: rgba, bytesPerPixel: 4), name: "f")
        let tip = try XCTUnwrap(grayImage(set.tips.values.first?.frames.first))
        XCTAssertEqual(gray(tip, 1, 1), 240)
        XCTAssertEqual(gray(tip, 1, 0), 80)
        // version 1: no magic, no spacing (defaults to 25%)
        var v1 = [UInt8]()
        func be(_ v: Int) { v1 += [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        be(20 + 4); be(1); be(2); be(1); be(1); v1 += Array("old\0".utf8); v1 += [255, 128]
        let s1 = try GIMPBrush.readGBR(data: Data(v1), name: "f")
        XCTAssertEqual(s1.brushes[0].name, "old")
        XCTAssertEqual(s1.brushes[0].params.spacing, 0.25, accuracy: 1e-9)
        // version 3 (CinePaint float16 gray)
        var v3 = [UInt8]()
        func be3(_ v: Int) { v3 += [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        be3(28 + 2); be3(3); be3(2); be3(1); be3(18); v3 += Array("GIMP".utf8); be3(10); v3 += Array("f\0".utf8)
        v3 += [0x3C, 0x00, 0x38, 0x00]   // 1.0, 0.5
        let s3 = try GIMPBrush.readGBR(data: Data(v3), name: "f")
        let t3 = try XCTUnwrap(grayImage(s3.tips.values.first?.frames.first))
        // 2×1 content in a 2×2 square: content row 0, padding row 1
        XCTAssertEqual([gray(t3, 0, 0), gray(t3, 1, 0), gray(t3, 0, 1), gray(t3, 1, 1)], [255, 128, 0, 0])
        // unsupported depth
        XCTAssertThrowsError(try GIMPBrush.readGBR(data: GIMPBrushWriter.gbr(name: "x", width: 1, height: 1, pixels: [0, 0, 0], bytesPerPixel: 3), name: "f"))
    }

    func testGIHImagePipe() throws {
        let cells: [(width: Int, height: Int, gray: [UInt8])] = [
            (4, 4, [UInt8](repeating: 255, count: 16)),
            (6, 2, [UInt8](repeating: 100, count: 12)),
            (3, 5, [UInt8](repeating: 50, count: 15)),
        ]
        let data = GIMPBrushWriter.gih(name: "Leaves", cells: cells, spacing: 60, selection: "random")
        XCTAssertTrue(GIMPBrush.looksLikeGIH(data))
        let set = try GIMPBrush.readGIH(data: data, name: "file")
        XCTAssertEqual(set.brushes.count, 1)
        let b = set.brushes[0]
        XCTAssertEqual(b.name, "Leaves")
        XCTAssertEqual(b.params.spacing, 0.6, accuracy: 1e-9)
        XCTAssertEqual(b.params.size, 6)
        let tip = try XCTUnwrap(set.tips[b.tipKey!])
        XCTAssertEqual(tip.frames.count, 3)
        XCTAssertEqual(tip.selection, .random)
        for f in tip.frames { XCTAssertEqual(grayImage(f)?.width, 6); XCTAssertEqual(grayImage(f)?.height, 6) }
        XCTAssertEqual(gray(grayImage(tip.frames[0])!, 2, 2), 255)
        XCTAssertEqual(gray(grayImage(tip.frames[0])!, 0, 0), 0)
        XCTAssertEqual(gray(grayImage(tip.frames[1])!, 0, 2), 100)
        XCTAssertEqual(gray(grayImage(tip.frames[1])!, 0, 1), 0)
        XCTAssertEqual(gray(grayImage(tip.frames[2])!, 0, 0), 0)
        XCTAssertEqual(gray(grayImage(tip.frames[2])!, 2, 3), 50)
        XCTAssertTrue(set.format.contains("3 frames"))
        // parameter parsing
        let p = GIMPBrush.parsePipeParams("8 ncells:8 cellwidth:31 dim:2 rank0:1 rank1:8 sel0:random sel1:angular")
        XCTAssertEqual(p.ncells, 8)
        XCTAssertEqual(p.selection, .angular)
        XCTAssertEqual(GIMPBrush.parsePipeParams("2 ncells:2 sel0:velocity").selection, .velocity)
        // truncated pipe keeps the cells before the damage
        let cut = try GIMPBrush.readGIH(data: data.prefix(data.count - 3), name: "f")
        XCTAssertEqual(cut.tips.values.first?.frames.count, 2)
        XCTAssertEqual(cut.skipped.count, 1)
    }

    // MARK: - Procreate

    private func shapePNG() -> Data { PNGCodec.encode(discTip(32)) }
    private func grainPNG() -> Data { PNGCodec.encode(grayBuffer(16, 16) { x, y in UInt8((x ^ y) * 16) }) }

    func testProcreateBrush() throws {
        var w = ZipWriter()
        w.add(name: "ABC-UUID/Brush.archive", data: BrushFormatVectors.bytes(BrushFormatVectors.archiveGrainy))
        w.add(name: "ABC-UUID/Shape.png", data: shapePNG())
        w.add(name: "ABC-UUID/Grain.png", data: grainPNG())
        w.add(name: "ABC-UUID/QuickLook/Thumbnail.png", data: PNGCodec.encode(grayBuffer(4, 4) { _, _ in 9 }))
        w.add(name: "ABC-UUID/Reset/Brush.archive", data: Data([1, 2, 3]))
        w.add(name: "__MACOSX/ABC-UUID/._Shape.png", data: Data([0, 5, 22, 7]))
        let set = try BrushImport.load(data: w.finish(), fileName: "/tmp/Grainy.brush")
        XCTAssertEqual(set.name, "Grainy")
        XCTAssertEqual(set.brushes.count, 1)
        let b = set.brushes[0]
        XCTAssertEqual(b.name, "Grainy Pencil")
        XCTAssertEqual(b.tipKey, "ABC-UUID")
        let p = b.params
        XCTAssertEqual(p.size, 50, accuracy: 1e-9)
        XCTAssertEqual(p.spacing, 0.15, accuracy: 1e-9)
        XCTAssertTrue(p.scatterEnabled); XCTAssertEqual(p.scatter, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.angleJitter, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.angleControl.source, .direction)
        XCTAssertTrue(p.pressureSize); XCTAssertEqual(p.minDiameter, 0.4, accuracy: 1e-9)
        XCTAssertFalse(p.pressureOpacity)
        XCTAssertEqual(p.sizeJitter, 0.3, accuracy: 1e-9)
        XCTAssertTrue(p.colorEnabled); XCTAssertEqual(p.hueJitter, 0.2, accuracy: 1e-9)
        XCTAssertEqual(p.textureScale, 0.75, accuracy: 1e-9)
        XCTAssertEqual(p.textureDepth, 0.8, accuracy: 1e-9)
        XCTAssertEqual(p.smoothing, 0.3, accuracy: 1e-9)
        XCTAssertEqual(p.opacity, 0.9, accuracy: 1e-9)
        XCTAssertTrue(p.flipXJitter); XCTAssertFalse(p.flipYJitter)
        XCTAssertTrue(p.textureEachTip)
        XCTAssertTrue(p.textureEnabled); XCTAssertEqual(p.texturePatternID, "ABC-UUID")
        XCTAssertEqual(set.patterns.count, 1)
        let grain = try XCTUnwrap(grayImage(set.patterns.first?.image))
        XCTAssertEqual(gray(grain, 1, 0), 16)
        let tip = try XCTUnwrap(grayImage(set.tips["ABC-UUID"]?.frames.first))
        XCTAssertEqual(tip.width, 32)
        XCTAssertEqual(gray(tip, 16, 16), 255)
        XCTAssertEqual(gray(tip, 0, 0), 0)
    }

    private func brushsetData(corruptThird: Bool = true) -> Data {
        var w = ZipWriter()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>name</key><string>My Set</string>
        <key>brushes</key><array><string>U2</string><string>U1</string></array></dict></plist>
        """
        w.add(name: "brushset.plist", data: Data(plist.utf8))
        w.add(name: "U1/Brush.archive", data: BrushFormatVectors.bytes(BrushFormatVectors.archiveGrainy))
        w.add(name: "U1/Shape.png", data: shapePNG())
        w.add(name: "U1/Grain.png", data: grainPNG())
        w.add(name: "U2/Brush.archive", data: BrushFormatVectors.bytes(BrushFormatVectors.archiveInk))
        w.add(name: "U2/Shape.png", data: shapePNG())
        if corruptThird {
            w.add(name: "U3/Brush.archive", data: Data("not a plist at all".utf8))
            w.add(name: "U3/Shape.png", data: Data("not a png".utf8))
        }
        return w.finish()
    }

    func testProcreateBrushset() throws {
        let set = try BrushImport.load(data: brushsetData(), fileName: "Pack.brushset")
        XCTAssertEqual(set.name, "My Set")
        XCTAssertEqual(set.brushes.map(\.name), ["Ink Pen", "Grainy Pencil", "Brush 3"])
        XCTAssertEqual(set.brushes[0].params.size, 10, accuracy: 1e-9)       // 0.04 × (500 × maxSize 0.5)
        XCTAssertEqual(set.brushes[0].params.spacing, 0.02, accuracy: 1e-9)
        XCTAssertFalse(set.brushes[0].params.textureEnabled)
        XCTAssertTrue(set.brushes[1].params.textureEnabled)
        XCTAssertEqual(set.patterns.map(\.id), ["U1"])
        // undecodable shape is passed on encoded; unreadable archive → defaults
        guard case .encoded(let d)? = set.tips["U3"]?.frames.first else { return XCTFail("expected encoded shape") }
        XCTAssertEqual(d, Data("not a png".utf8))
        XCTAssertEqual(set.brushes[2].params.spacing, BrushParams().spacing)
    }

    // MARK: - Krita

    private func kpp(_ xml: String, compressed: Bool = true, thumbnail: PixelBuffer? = nil) -> Data {
        PNGCodec.encode(thumbnail ?? rgbaBuffer(8, 8) { _, _ in (255, 255, 255, 255) }, text: [("version", "5.0"), ("preset", xml)],
                        compressText: compressed)
    }

    func testKritaAutoBrush() throws {
        let brushDef = """
        <Brush useAutoSpacing="0" angle="1.5707963267948966" spacing="0.1" randomness="0" BrushVersion="2" type="auto_brush" density="1">
         <MaskGenerator spikes="2" hfade="0.7" ratio="0.5" diameter="40" id="default" type="circle" antialiasEdges="1" vfade="0.7"/>
        </Brush>
        """
        let esc = brushDef.replacingOccurrences(of: "&", with: "&amp;")
        let xml = """
        <!DOCTYPE preset>
        <Preset paintopid="paintbrush" name="b) Basic &amp; Round">
         <param type="string" name="brush_definition"><![CDATA[\(esc)]]></param>
         <param type="string" name="OpacityValue"><![CDATA[0.8]]></param>
         <!-- a comment -->
         <param type="string" name="FlowValue">0.5</param>
        </Preset>
        """
        let data = kpp(xml)
        XCTAssertTrue(KritaPreset.isKritaPreset(data))
        let set = try BrushImport.load(data: data, fileName: "basic.kpp")
        let b = try XCTUnwrap(set.brushes.first)
        XCTAssertEqual(b.name, "b) Basic & Round")
        XCTAssertNil(b.tipKey)
        XCTAssertEqual(b.params.size, 40)
        XCTAssertEqual(b.params.roundness, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b.params.hardness, 0.7, accuracy: 1e-9)
        XCTAssertEqual(b.params.spacing, 0.1, accuracy: 1e-9)
        XCTAssertEqual(b.params.angle, 90, accuracy: 1e-6)
        XCTAssertEqual(b.params.opacity, 0.8, accuracy: 1e-9)
        XCTAssertEqual(b.params.flow, 0.5, accuracy: 1e-9)
        // auto spacing: coefficient / √diameter
        let auto = xml.replacingOccurrences(of: "useAutoSpacing=\"0\"", with: "useAutoSpacing=\"1\" autoSpacingCoeff=\"0.8\"")
            .replacingOccurrences(of: "diameter=\"40\"", with: "diameter=\"16\"")
        let s2 = try KritaPreset.read(data: kpp(auto, compressed: false), name: "x")
        XCTAssertEqual(s2.brushes[0].params.spacing, 0.2, accuracy: 1e-9)   // 0.8 / √16
    }

    func testKritaEmbeddedGBRAndFallback() throws {
        let gbr = GIMPBrushWriter.gbr(name: "dot", width: 3, height: 3, pixels: [0, 0, 0, 0, 255, 0, 0, 0, 0], spacing: 30)
        let xml = """
        <Preset paintopid="paintbrush" name="Pinsel ✓">
         <param type="string" name="brush_definition"><![CDATA[<Brush type="gbr_brush" filename="dots/dot.gbr" spacing="0.3" angle="0" scale="2" BrushVersion="2"/>]]></param>
         <resources><resource type="brushes" name="dot" filename="dot.gbr" md5sum="00">\n\(gbr.base64EncodedString(options: .lineLength64Characters))\n</resource></resources>
        </Preset>
        """
        let set = try KritaPreset.read(data: kpp(xml), name: "file")
        let b = try XCTUnwrap(set.brushes.first)
        XCTAssertEqual(b.name, "Pinsel ✓")
        XCTAssertEqual(b.params.size, 6)                 // 3 px × scale 2
        XCTAssertEqual(b.params.spacing, 0.3, accuracy: 1e-9)
        let tip = try XCTUnwrap(grayImage(set.tips[b.tipKey!]?.frames.first))
        XCTAssertEqual(gray(tip, 1, 1), 255)
        XCTAssertEqual(gray(tip, 0, 0), 0)
        // png_brush without its resource → the preset thumbnail (dark square on white) becomes the tip
        let missing = """
        <Preset paintopid="paintbrush" name="Lost"><param type="string" name="brush_definition"><![CDATA[<Brush type="png_brush" filename="gone.png" spacing="0.2"/>]]></param></Preset>
        """
        let thumb = rgbaBuffer(10, 10) { x, y in (3..<7).contains(x) && (3..<7).contains(y) ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let s2 = try KritaPreset.read(data: kpp(missing, thumbnail: thumb), name: "file")
        let t2 = try XCTUnwrap(grayImage(s2.tips[s2.brushes[0].tipKey!]?.frames.first))
        XCTAssertEqual(gray(t2, 5, 5), 255)
        XCTAssertEqual(gray(t2, 0, 0), 0)
        XCTAssertEqual(s2.brushes[0].params.spacing, 0.2, accuracy: 1e-9)
        // a PNG without preset XML still imports as a tip when named .kpp
        let s3 = try BrushImport.load(data: PNGCodec.encode(thumb), fileName: "x.kpp")
        XCTAssertEqual(s3.brushes.count, 1)
    }

    func testMiniXML() {
        let root = MiniXML.parse("<?xml version='1.0'?><a x='1' y=\"&lt;2&gt;\"><b/><c>t&amp;&#65;&#x42;<![CDATA[<raw>]]></c><unclosed></a>")
        XCTAssertEqual(root?.name, "a")
        XCTAssertEqual(root?.attributes["y"], "<2>")
        XCTAssertEqual(root?.child("c")?.text, "t&AB<raw>")
        XCTAssertEqual(root?.descendants(named: "b").count, 1)
        XCTAssertNil(MiniXML.parse("just text"))
        let deep = String(repeating: "<d>", count: 5000)
        XCTAssertNotNil(MiniXML.parse(deep))
    }

    // MARK: - ImageCrat brush-set archive

    private func sampleSet() -> ImportedBrushSet {
        var set = ImportedBrushSet(name: "Round Trip", format: "test")
        set.tips["disc"] = ImportedTipImage(.gray(discTip(9)))
        set.tips["anim/1"] = ImportedTipImage(frames: [.gray(discTip(5)), .gray(grayBuffer(5, 5) { x, _ in UInt8(x * 50) })], selection: .angular)
        set.tips["enc"] = ImportedTipImage(.encoded(Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])))
        set.patterns = [
            ImportedPattern(id: "paper", name: "Paper", image: .gray(grayBuffer(4, 4) { x, y in UInt8(x * 60 + y) })),
            ImportedPattern(id: "colour", name: "Colour", image: .gray(rgbaBuffer(3, 3) { x, _ in (UInt8(x * 100), 50, 20, 255) })),
            ImportedPattern(id: "raw", name: "Raw", image: .encoded(Data("GIF89a....".utf8))),
        ]
        var p1 = BrushParams(size: 42, hardness: 0.3, spacing: 0.07, angle: 15, roundness: 0.6)
        p1.textureEnabled = true; p1.texturePatternID = "paper"; p1.sizeControl = BrushControlParam(source: .tilt, fadeSteps: 12)
        set.brushes = [
            ImportedBrush(name: "Disc", folderPath: ["Group", "Sub"], tipKey: "disc", params: p1, color: RGBA(r: 1, g: 0.5, b: 0, a: 1),
                          includesSize: false, includesToolSettings: true),
            ImportedBrush(name: "Anim", tipKey: "anim/1", params: BrushParams()),
            ImportedBrush(name: "Round", tipKey: nil, params: BrushParams(size: 12)),
            ImportedBrush(name: "Encoded", tipKey: "enc", params: BrushParams()),
        ]
        return set
    }

    func testBrushSetArchiveRoundTrip() throws {
        let src = sampleSet()
        let data = BrushSetArchive.write(src)
        XCTAssertEqual(BrushImport.detect(data: data, fileName: "x.zip"), .icbrushes)
        let set = try BrushImport.load(data: data, fileName: "whatever.icbrushes")
        XCTAssertEqual(set.name, "Round Trip")
        XCTAssertEqual(set.brushes.map(\.name), ["Disc", "Anim", "Round", "Encoded"])
        XCTAssertEqual(set.brushes[0].folderPath, ["Group", "Sub"])
        XCTAssertEqual(set.brushes[0].params, src.brushes[0].params)
        XCTAssertEqual(set.brushes[0].color, RGBA(r: 1, g: 0.5, b: 0, a: 1))
        XCTAssertFalse(set.brushes[0].includesSize)
        XCTAssertTrue(set.brushes[0].includesToolSettings)
        XCTAssertNil(set.brushes[2].tipKey)
        XCTAssertEqual(set.brushes[2].params.size, 12)
        XCTAssertEqual(set.skipped, [])
        let disc = try XCTUnwrap(grayImage(set.tips["disc"]?.frames.first))
        let orig = discTip(9)
        for y in 0..<9 { for x in 0..<9 { XCTAssertEqual(gray(disc, x, y), gray(orig, x, y)) } }
        XCTAssertEqual(set.tips["anim/1"]?.frames.count, 2)
        XCTAssertEqual(set.tips["anim/1"]?.selection, .angular)
        XCTAssertEqual(gray(try XCTUnwrap(grayImage(set.tips["anim/1"]?.frames[1])), 3, 0), 150)
        guard case .encoded(let e)? = set.tips["enc"]?.frames.first else { return XCTFail("encoded tip") }
        XCTAssertEqual(e, Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))
        XCTAssertEqual(set.patterns.map(\.id), ["paper", "colour", "raw"])
        XCTAssertEqual(try XCTUnwrap(grayImage(set.patterns[0].image)).format, .gray)
        XCTAssertEqual(gray(try XCTUnwrap(grayImage(set.patterns[0].image)), 2, 1), 121)
        let colour = try XCTUnwrap(grayImage(set.patterns[1].image))
        XCTAssertEqual(colour.format, .rgba)
        XCTAssertEqual(colour.pixel(2, 0).0, 200)
        guard case .encoded = set.patterns[2].image else { return XCTFail("encoded pattern") }
    }

    private func archive(manifest: String, files: [String: Data] = [:]) -> Data {
        var w = ZipWriter()
        for (k, v) in files { w.add(name: k, data: v) }
        w.add(name: "manifest.json", data: Data(manifest.utf8))
        return w.finish()
    }

    func testBrushSetArchiveVersioningAndTolerance() throws {
        XCTAssertThrowsError(try BrushSetArchive.read(archive(manifest: #"{"format":"imagecrat-brushes","version":2,"brushes":[]}"#))) {
            XCTAssertEqual($0 as? BrushImportError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try BrushSetArchive.read(archive(manifest: #"{"format":"something-else","version":1}"#)))
        XCTAssertThrowsError(try BrushSetArchive.read(archive(manifest: "{not json")))
        let minimal = try BrushSetArchive.read(archive(manifest: #"{"format":"imagecrat-brushes","brushes":[{"name":"X"}]}"#))
        XCTAssertEqual(minimal.brushes.map(\.name), ["X"])
        XCTAssertEqual(minimal.brushes[0].params, { var p = BrushParams(); p.sanitize(); return p }())
        let messy = try BrushSetArchive.read(archive(manifest: """
        {"format":"imagecrat-brushes","version":"1.4","name":7,
         "brushes":[5, {"name":"Y","tip":"gone","params":{"size":"big","spacing":0.5,"futureKey":1},"folder":"notarray"}],
         "tips":{"t":{"frames":["missing.png"]}, "u": 3},
         "patterns":[{"id":"p","file":"nope.png"}], "future":{"x":1}}
        """))
        XCTAssertEqual(messy.name, "Brushes")
        XCTAssertEqual(messy.brushes.map(\.name), ["Y"])                 // the non-object element is dropped
        XCTAssertNil(messy.brushes[0].tipKey)
        XCTAssertEqual(messy.brushes[0].folderPath, [])
        XCTAssertEqual(messy.brushes[0].params.spacing, 0.5)
        XCTAssertEqual(messy.brushes[0].params.size, BrushParams().size)
        XCTAssertFalse(messy.skipped.isEmpty)
    }

    // MARK: - Coverage rule

    func testCoverageRule() {
        // opaque, dark mark on white → 1 − lum
        let a = BrushTipImaging.grayCoverage(fromRGBA: rgbaBuffer(10, 10) { x, _ in x == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) })
        XCTAssertEqual(gray(a, 0, 5), 255); XCTAssertEqual(gray(a, 5, 5), 0)
        // opaque, mostly dark → lum (white-on-black tip)
        let b = BrushTipImaging.grayCoverage(fromRGBA: rgbaBuffer(10, 10) { x, _ in x == 0 ? (255, 255, 255, 255) : (0, 0, 0, 255) })
        XCTAssertEqual(gray(b, 0, 5), 255); XCTAssertEqual(gray(b, 5, 5), 0)
        // transparency with dark content → alpha × (1 − lum)
        let c = BrushTipImaging.grayCoverage(fromRGBA: rgbaBuffer(10, 10) { x, _ in x < 5 ? (0, 0, 0, 200) : (128, 128, 128, 0) })
        XCTAssertEqual(gray(c, 1, 1), 200); XCTAssertEqual(gray(c, 8, 1), 0)
        let c2 = BrushTipImaging.grayCoverage(fromRGBA: rgbaBuffer(2, 100) { _, y in y == 0 ? (128, 128, 128, 255) : (0, 0, 0, y < 50 ? 255 : 0) })
        XCTAssertEqual(Int(gray(c2, 0, 0)), 127, accuracy: 1)
        // transparency with light content → alpha
        let d = BrushTipImaging.grayCoverage(fromRGBA: rgbaBuffer(10, 10) { x, _ in x < 5 ? (255, 255, 255, 180) : (0, 0, 0, 0) })
        XCTAssertEqual(gray(d, 1, 1), 180); XCTAssertEqual(gray(d, 8, 1), 0)
        // gray input = opaque grayscale image
        let e = BrushTipImaging.grayCoverage(fromRGBA: grayBuffer(4, 4) { x, _ in x == 0 ? 0 : 255 })
        XCTAssertEqual(gray(e, 0, 0), 255); XCTAssertEqual(gray(e, 2, 0), 0)
        // padding
        let sq = BrushTipImaging.squareGray([1, 2, 3, 4, 5, 6], width: 3, height: 2)
        XCTAssertEqual(sq.width, 3); XCTAssertEqual(sq.height, 3)
        XCTAssertEqual([gray(sq, 0, 0), gray(sq, 0, 1), gray(sq, 2, 1), gray(sq, 2, 2)], [1, 4, 6, 0])
    }

    // MARK: - Sniffer

    func testBrushImportDispatch() throws {
        let gbr = GIMPBrushWriter.gbr(name: "", width: 2, height: 2, pixels: [1, 2, 3, 4])
        XCTAssertEqual(BrushImport.detect(data: gbr, fileName: "a.bin"), .gbr)
        XCTAssertEqual(try BrushImport.load(data: gbr, fileName: "dir/My Brush.gbr").brushes.first?.name, "My Brush")
        let gih = GIMPBrushWriter.gih(name: "P", cells: [(2, 2, [1, 2, 3, 4])])
        XCTAssertEqual(BrushImport.detect(data: gih, fileName: "x"), .gih)
        XCTAssertEqual(BrushImport.detect(data: brushsetData(corruptThird: false), fileName: "x.zip"), .procreate)
        XCTAssertEqual(BrushImport.detect(data: Data([0, 6, 0, 2, 0x38, 0x42, 0x49, 0x4D, 0, 0, 0, 0]), fileName: "noext"), .abr)
        XCTAssertEqual(BrushImport.detect(data: Data([1, 2, 3]), fileName: "set.tpl"), .tpl)
        let plain = PNGCodec.encode(grayBuffer(3, 3) { _, _ in 0 })
        XCTAssertNil(BrushImport.detect(data: plain, fileName: "pic.png"))
        XCTAssertTrue(BrushImport.isPlainImage(data: plain, fileName: "pic.png"))
        XCTAssertTrue(BrushImport.isPlainImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]), fileName: "noext"))
        XCTAssertFalse(BrushImport.isPlainImage(data: gbr, fileName: "a.gbr"))
        XCTAssertThrowsError(try BrushImport.load(data: plain, fileName: "pic.png")) {
            guard case .unsupportedFormat? = $0 as? BrushImportError else { return XCTFail("\($0)") }
        }
        var w = ZipWriter(); w.add(name: "readme.txt", data: Data("hi".utf8))
        XCTAssertThrowsError(try BrushImport.load(data: w.finish(), fileName: "x.zip"))
        XCTAssertEqual(BrushImport.baseName("/a/b/c.d.brushset"), "c.d")
        XCTAssertEqual(BrushImport.fileExtension("X.KPP"), "kpp")
        XCTAssertEqual(Set(BrushImport.supportedExtensions), ["abr", "tpl", "gbr", "gih", "brush", "brushset", "kpp", "icbrushes"])
    }

    // MARK: - Robustness (no crashes on damaged input)

    func testFuzzInflateZipPNG() {
        let V = BrushFormatVectors.self
        fuzz(V.bytes(V.zlibDefault), seed: 1) { _ = try? Inflate.zlibDecompress($0, maxOutput: 1 << 20) }
        fuzz(V.bytes(V.rawFixed), seed: 2) { _ = try? Inflate.inflateRaw($0, maxOutput: 1 << 20) }
        fuzz(V.bytes(V.zipDeflated), seed: 3) { d in
            guard let z = try? ZipReader(data: d) else { return }
            for e in z.entries { _ = try? z.data(for: e) }
        }
        fuzz(V.bytes(V.zipDataDescriptor), seed: 4, iterations: 150) { d in
            guard let z = try? ZipReader(data: d) else { return }
            for e in z.entries { _ = try? z.data(for: e) }
        }
        for (i, c) in V.pngCases.enumerated() where ["p4i", "rgb16", "g2", "ga8i"].contains(c.0) {
            fuzz(V.bytes(c.3), seed: 10 + UInt64(i), iterations: 150) { _ = PNGCodec.decode($0) }
        }
        fuzz(V.bytes(V.pngText), seed: 5) { _ = PNGCodec.textChunks($0) }
    }

    func testFuzzPlists() {
        let V = BrushFormatVectors.self
        fuzz(V.bytes(V.bplistGeneral), seed: 20) { _ = try? BinaryPlist.parse($0) }
        fuzz(V.bytes(V.archiveGrainy), seed: 21) { _ = BinaryPlist.unarchiveRoot($0) }
        fuzz(Data(V.xmlPlistGeneral.utf8), seed: 22, iterations: 100) { _ = try? BinaryPlist.parse($0) }
    }

    func testFuzzGIMP() {
        let gbr = GIMPBrushWriter.gbr(name: "fuzz", width: 7, height: 5, pixels: (0..<35).map { UInt8($0 * 7) })
        fuzz(gbr, seed: 30) { _ = try? BrushImport.load(data: $0, fileName: "f.gbr") }
        let rgba = GIMPBrushWriter.gbr(name: "fuzz", width: 3, height: 3, pixels: (0..<36).map { UInt8($0 * 7) }, bytesPerPixel: 4)
        fuzz(rgba, seed: 31) { _ = try? GIMPBrush.readGBR(data: $0, name: "f") }
        let gih = GIMPBrushWriter.gih(name: "pipe", cells: [(3, 3, [UInt8](repeating: 9, count: 9)), (2, 4, [UInt8](repeating: 1, count: 8))])
        fuzz(gih, seed: 32) { _ = try? BrushImport.load(data: $0, fileName: "f.gih") }
    }

    func testFuzzProcreateKritaArchive() {
        var w = ZipWriter()
        w.add(name: "Brush.archive", data: BrushFormatVectors.bytes(BrushFormatVectors.archiveInk))
        w.add(name: "Shape.png", data: PNGCodec.encode(discTip(8)))
        w.add(name: "Grain.png", data: PNGCodec.encode(grayBuffer(4, 4) { x, _ in UInt8(x * 60) }))
        fuzz(w.finish(), seed: 40) { _ = try? BrushImport.load(data: $0, fileName: "f.brush") }
        fuzz(brushsetData(), seed: 41, iterations: 150) { _ = try? BrushImport.load(data: $0, fileName: "f.brushset") }
        let gbr = GIMPBrushWriter.gbr(name: "dot", width: 3, height: 3, pixels: [0, 0, 0, 0, 255, 0, 0, 0, 0])
        let xml = """
        <Preset paintopid="paintbrush" name="F"><param type="string" name="brush_definition"><![CDATA[<Brush type="gbr_brush" filename="dot.gbr" spacing="0.3"/>]]></param><resources><resource type="brushes" filename="dot.gbr">\(gbr.base64EncodedString())</resource></resources></Preset>
        """
        let k = kpp(xml, compressed: false)
        fuzz(k, seed: 42) { _ = try? BrushImport.load(data: $0, fileName: "f.kpp") }
        fuzz(Data(xml.utf8), seed: 43) { _ = MiniXML.parse(String(decoding: $0, as: UTF8.self)) }
        var small = ImportedBrushSet(name: "S")
        small.tips["t"] = ImportedTipImage(.gray(discTip(6)))
        small.patterns = [ImportedPattern(id: "p", name: "P", image: .gray(grayBuffer(3, 3) { _, _ in 7 }))]
        small.brushes = [ImportedBrush(name: "B", folderPath: ["G"], tipKey: "t", params: BrushParams())]
        let icb = BrushSetArchive.write(small)
        fuzz(icb, seed: 44) { _ = try? BrushImport.load(data: $0, fileName: "f.icbrushes") }
        // the manifest itself, damaged inside a valid zip
        let manifest = try? ZipReader(data: icb).data(for: "manifest.json")
        fuzz(manifest ?? Data(), seed: 45, iterations: 200) { m in
            var z = ZipWriter()
            z.add(name: "tips/0-t_0.png", data: PNGCodec.encode(discTip(6)))
            z.add(name: "manifest.json", data: m)
            _ = try? BrushSetArchive.read(z.finish())
        }
    }
}
