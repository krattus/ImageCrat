import XCTest
@testable import ImageCratCore

/// Photoshop .abr / .tpl reading and writing with synthetic files built from the published layout.
final class ABRBrushTests: XCTestCase {
    // MARK: Builders

    static func u8(_ v: Int, _ d: inout Data) { d.append(UInt8(truncatingIfNeeded: v)) }
    static func u16(_ v: Int, _ d: inout Data) { u8(v >> 8, &d); u8(v, &d) }
    static func u32(_ v: Int, _ d: inout Data) { u16(v >> 16, &d); u16(v, &d) }

    /// A w×h gray ring (255 = paint).
    static func ring(_ w: Int, _ h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x) - Double(w) / 2 + 0.5, dy = Double(y) - Double(h) / 2 + 0.5
                let r = sqrt(dx * dx / Double(w * w) + dy * dy / Double(h * h)) * 2
                px[y * w + x] = r < 0.9 && r > 0.5 ? 255 : (r <= 0.5 ? 60 : 0)
            }
        }
        return px
    }

    static func gray(_ px: [UInt8], _ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h, format: .gray)
        let d = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { d[y * b.bytesPerRow + x] = px[y * w + x] } }
        return b
    }

    static func px(_ b: PixelBuffer, _ x: Int, _ y: Int) -> UInt8 { b.data.assumingMemoryBound(to: UInt8.self)[y * b.bytesPerRow + x] }

    /// `samp` entry: subversion 2 layout (key, 264 unused bytes, bounds, depth, compression, data).
    static func sampleEntry(key: String, w: Int, h: Int, depth: Int = 8, rle: Bool = false, px: [UInt8]) -> Data {
        var b = Data()
        let k = Array(key.utf8)
        u8(k.count, &b); b.append(contentsOf: k)
        b.append(Data(count: 264))
        u32(0, &b); u32(0, &b); u32(h, &b); u32(w, &b)
        u16(depth, &b)
        u8(rle ? 1 : 0, &b)
        if rle {
            let rows = (0..<h).map { ABRBitmap.packBits(px[($0 * w)..<(($0 + 1) * w)]) }
            for r in rows { u16(r.count, &b) }
            for r in rows { b.append(contentsOf: r) }
        } else if depth == 16 {
            for v in px { u16(Int(v) * 257, &b) }
        } else {
            b.append(contentsOf: px)
        }
        var e = Data()
        u32(b.count, &e); e.append(b)
        while e.count % 4 != 0 { e.append(0) }
        return e
    }

    static func section(_ tag: String, _ body: Data) -> Data {
        var d = Data(Array("8BIM".utf8)); d.append(contentsOf: Array(tag.utf8)); u32(body.count, &d); d.append(body); return d
    }

    typealias V = PSDDescriptorValue
    static func prc(_ v: Double) -> V { .unitFloat(unit: "#Prc", value: v) }
    static func brVr(_ code: Int, jitter: Double, min: Double = 0, fade: Int = 25) -> V {
        .object(PSDDescriptor(classID: "brVr", [("bVTy", .integer(Int32(code))), ("fStp", .integer(Int32(fade))), ("jitter", prc(jitter)), ("Mnm ", prc(min))]))
    }

    /// A sampled preset with most of the Brush Settings panel switched on.
    static func richPreset(_ name: String, key: String, dualKey: String, patternID: String) -> V {
        .object(PSDDescriptor(classID: "brushPreset", [
            ("Nm  ", .string(name)),
            ("Brsh", .object(PSDDescriptor(classID: "sampledBrush", [
                ("Nm  ", .string(name)), ("Dmtr", .unitFloat(unit: "#Pxl", value: 64)), ("Angl", .unitFloat(unit: "#Ang", value: 30)),
                ("Rndn", prc(80)), ("Spcn", prc(35)), ("Intr", .bool(true)), ("flipX", .bool(true)), ("flipY", .bool(false)),
                ("sampledData", .string("$" + key)),
            ]))),
            ("useTipDynamics", .bool(true)), ("flipX", .bool(false)), ("flipY", .bool(true)),
            ("minimumDiameter", prc(20)), ("minimumRoundness", prc(40)), ("tiltScale", prc(50)),
            ("szVr", brVr(2, jitter: 30)), ("angleDynamics", brVr(7, jitter: 10)), ("roundnessDynamics", brVr(1, jitter: 25, fade: 40)),
            ("useScatter", .bool(true)), ("bothAxes", .bool(true)), ("Cnt ", .double(3)),
            ("scatterDynamics", brVr(0, jitter: 150)), ("countDynamics", brVr(0, jitter: 50)),
            ("useTexture", .bool(true)), ("Txtr", .object(PSDDescriptor(classID: "Ptrn", [("Nm  ", .string("Paper")), ("Idnt", .string(patternID))]))),
            ("TxtC", .bool(true)), ("InvT", .bool(true)), ("textureBlendMode", .enumerated(type: "BlnM", value: "Sbtr")),
            ("textureDepth", prc(70)), ("minimumDepth", prc(10)), ("textureDepthDynamics", brVr(2, jitter: 5)),
            ("textureScale", prc(150)), ("textureBrightness", .integer(12)), ("textureContrast", .integer(-8)), ("protectTexture", .bool(true)),
            ("dualBrush", .object(PSDDescriptor(classID: "dualBrush", [
                ("useDualBrush", .bool(true)), ("Flip", .bool(true)), ("BlnM", .enumerated(type: "BlnM", value: "CBrn")),
                ("Brsh", .object(PSDDescriptor(classID: "sampledBrush", [("Dmtr", .unitFloat(unit: "#Pxl", value: 22)), ("Spcn", prc(40)), ("sampledData", .string(dualKey))]))),
                ("useScatter", .bool(true)), ("Cnt ", .double(2)), ("bothAxes", .bool(true)), ("scatterDynamics", brVr(0, jitter: 80)),
            ]))),
            ("useColorDynamics", .bool(true)), ("clVr", brVr(2, jitter: 60)), ("H   ", prc(12)), ("Strt", prc(20)), ("Brgh", prc(30)), ("purity", prc(-15)),
            ("colorDynamicsPerTip", .bool(false)),
            ("usePaintDynamics", .bool(true)), ("opVr", brVr(2, jitter: 40, min: 10)), ("prVr", brVr(4, jitter: 20, min: 5)),
            ("useBrushPose", .bool(true)), ("overridePoseAngle", .bool(true)), ("brushPoseAngle", .integer(45)), ("brushPosePressure", prc(60)),
            ("overridePosePressure", .bool(true)), ("brushPoseTiltX", .integer(-30)),
            ("Wtdg", .bool(true)), ("Nose", .bool(true)), ("Rpt ", .bool(true)), ("Smoo", .bool(true)),
        ]))
    }

    static func computedPreset(_ name: String, d: Double, hard: Double) -> V {
        .object(PSDDescriptor(classID: "brushPreset", [
            ("Nm  ", .string(name)),
            ("Brsh", .object(PSDDescriptor(classID: "computedBrush", [("Dmtr", .unitFloat(unit: "#Pxl", value: d)), ("Hrdn", prc(hard)),
                                                                      ("Angl", .unitFloat(unit: "#Ang", value: 0)), ("Rndn", prc(100)), ("Spcn", prc(25))]))),
        ]))
    }

    static func group(_ name: String, _ items: [V]) -> V {
        .object(PSDDescriptor(classID: "brushGroup", [("Nm  ", .string(name)), ("Brsh", .list(items))]))
    }

    /// One gray pattern in the .pat layout.
    static func pattern(id: String, name: String, w: Int, h: Int) -> Data {
        var body = Data()
        u32(1, &body); u32(1, &body); u16(h, &body); u16(w, &body)
        let n = Array(name.utf16) + [0]
        u32(n.count, &body); for c in n { u16(Int(c), &body) }
        u8(id.utf8.count, &body); body.append(contentsOf: Array(id.utf8))
        var ch = Data()
        u32(8, &ch); u32(0, &ch); u32(0, &ch); u32(h, &ch); u32(w, &ch); u16(8, &ch); u8(0, &ch)
        for y in 0..<h { for x in 0..<w { u8((x * 255 / max(1, w - 1) + y) & 255, &ch) } }
        var vma = Data()
        u32(0, &vma); u32(0, &vma); u32(h, &vma); u32(w, &vma); u32(24, &vma)
        u32(1, &vma); u32(ch.count, &vma); vma.append(ch)
        u32(3, &body); u32(vma.count, &body); body.append(vma)
        var e = Data(); u32(body.count, &e); e.append(body)
        while e.count % 4 != 0 { e.append(0) }
        return e
    }

    /// v10.2 file: three sampled tips (8-bit raw, RLE, 16-bit), a pattern, presets in nested groups and a computed one.
    static func abrV10() -> Data {
        let k1 = "11111111-2222-3333-4444-555555555555", k2 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", k3 = "99999999-8888-7777-6666-555555555555"
        var samp = Data()
        samp.append(sampleEntry(key: k1, w: 40, h: 30, px: ring(40, 30)))
        samp.append(sampleEntry(key: k2, w: 16, h: 16, rle: true, px: ring(16, 16)))
        samp.append(sampleEntry(key: k3, w: 20, h: 24, depth: 16, px: ring(20, 24)))
        let patt = pattern(id: "pat-0001", name: "Paper", w: 12, h: 10)
        let root = PSDDescriptor(classID: "null", [("Brsh", .list([
            computedPreset("Hard Round 19", d: 19, hard: 100),
            group("Inkers", [
                richPreset("Kyle Ink", key: k1, dualKey: k2, patternID: "pat-0001"),
                group("Wet", [.object(PSDDescriptor(classID: "brushPreset", [("Nm  ", .string("Deep")),
                    ("Brsh", .object(PSDDescriptor(classID: "sampledBrush", [("Dmtr", .unitFloat(unit: "#Pxl", value: 24)), ("Spcn", prc(10)), ("sampledData", .string(k3))])))]))]),
            ]),
        ]))])
        var d = Data()
        u16(10, &d); u16(2, &d)
        d.append(section("samp", samp))
        d.append(section("patt", patt))
        d.append(section("desc", root.serializedVersioned()))
        return d
    }

    /// v2 file: one computed and one sampled brush.
    static func abrV2() -> Data {
        var computed = Data()
        u32(0, &computed); u16(30, &computed); u16(25, &computed); u16(50, &computed); u16(45, &computed); u16(70, &computed)
        var sampled = Data()
        u32(0, &sampled); u16(15, &sampled)
        let name = Array("Leaf".utf16)
        u32(name.count + 1, &sampled); for c in name { u16(Int(c), &sampled) }; u16(0, &sampled)
        u8(1, &sampled); u16(0, &sampled); u16(0, &sampled); u16(12, &sampled); u16(10, &sampled)
        u32(0, &sampled); u32(0, &sampled); u32(12, &sampled); u32(10, &sampled); u16(8, &sampled); u8(0, &sampled)
        sampled.append(contentsOf: ring(10, 12))
        var d = Data()
        u16(2, &d); u16(2, &d)
        u16(1, &d); u32(computed.count, &d); d.append(computed)
        u16(2, &d); u32(sampled.count, &d); d.append(sampled)
        return d
    }

    // MARK: Tests

    func testV10PresetSettingsGroupsAndPatterns() throws {
        let set = try ABRBrushReader.read(data: Self.abrV10(), name: "Kyle's Inkers")
        XCTAssertEqual(set.brushes.map(\.name), ["Hard Round 19", "Kyle Ink", "Deep"])
        XCTAssertEqual(set.brushes.map(\.folderPath), [[], ["Inkers"], ["Inkers", "Wet"]])
        XCTAssertEqual(set.patterns.count, 1)
        XCTAssertEqual(set.patterns.first?.name, "Paper")
        XCTAssertTrue(set.skipped.isEmpty, "\(set.skipped)")

        let round = set.brushes[0]
        XCTAssertNil(round.tipKey)
        XCTAssertEqual(round.params.size, 19, accuracy: 0.01)
        XCTAssertEqual(round.params.hardness, 1, accuracy: 0.01)

        let ink = set.brushes[1]
        let p = ink.params
        XCTAssertEqual(p.size, 64, accuracy: 0.01)
        XCTAssertEqual(p.angle, 30, accuracy: 0.01)
        XCTAssertEqual(p.roundness, 0.8, accuracy: 0.001)
        XCTAssertEqual(p.spacing, 0.35, accuracy: 0.001)
        XCTAssertTrue(p.flipX); XCTAssertFalse(p.flipY)
        XCTAssertTrue(p.shapeEnabled); XCTAssertTrue(p.flipYJitter); XCTAssertFalse(p.flipXJitter)
        XCTAssertEqual(p.sizeControl.source, .pressure); XCTAssertEqual(p.sizeJitter, 0.3, accuracy: 0.001)
        XCTAssertEqual(p.minDiameter, 0.2, accuracy: 0.001); XCTAssertEqual(p.tiltScale, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.angleControl.source, .direction); XCTAssertEqual(p.angleJitter, 0.1, accuracy: 0.001)
        XCTAssertEqual(p.roundnessControl.source, .fade); XCTAssertEqual(p.roundnessControl.fadeSteps, 40)
        XCTAssertEqual(p.minRoundness, 0.4, accuracy: 0.001)
        XCTAssertTrue(p.scatterEnabled); XCTAssertEqual(p.scatter, 1.5, accuracy: 0.001); XCTAssertTrue(p.scatterBothAxes)
        XCTAssertEqual(p.count, 3); XCTAssertEqual(p.countJitter, 0.5, accuracy: 0.001)
        XCTAssertTrue(p.textureEnabled); XCTAssertEqual(p.texturePatternID, "pat-0001"); XCTAssertEqual(p.texturePatternName, "Paper")
        XCTAssertTrue(p.textureInvert); XCTAssertEqual(p.textureMode, .subtract); XCTAssertEqual(p.textureDepth, 0.7, accuracy: 0.001)
        XCTAssertEqual(p.textureMinDepth, 0.1, accuracy: 0.001); XCTAssertEqual(p.textureScale, 1.5, accuracy: 0.001)
        XCTAssertEqual(p.textureBrightness, 12); XCTAssertEqual(p.textureContrast, -8); XCTAssertTrue(p.protectTexture)
        XCTAssertTrue(p.dualEnabled); XCTAssertEqual(p.dualMode, .colorBurn); XCTAssertEqual(p.dualSize, 22, accuracy: 0.01)
        XCTAssertEqual(p.dualSpacing, 0.4, accuracy: 0.001); XCTAssertEqual(p.dualScatter, 0.8, accuracy: 0.001); XCTAssertEqual(p.dualCount, 2)
        XCTAssertEqual(p.dualTipID, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertNotNil(set.tips[p.dualTipID])
        XCTAssertTrue(p.colorEnabled); XCTAssertEqual(p.fgBgJitter, 0.6, accuracy: 0.001); XCTAssertEqual(p.hueJitter, 0.12, accuracy: 0.001)
        XCTAssertEqual(p.purity, -0.15, accuracy: 0.001); XCTAssertFalse(p.colorPerTip)
        XCTAssertTrue(p.transferEnabled); XCTAssertEqual(p.opacityControl.source, .pressure); XCTAssertEqual(p.minOpacity, 0.1, accuracy: 0.001)
        XCTAssertEqual(p.flowControl.source, .wheel); XCTAssertEqual(p.flowJitter, 0.2, accuracy: 0.001)
        XCTAssertTrue(p.poseEnabled); XCTAssertTrue(p.poseOverrideRotation); XCTAssertEqual(p.poseRotation, 45)
        XCTAssertEqual(p.posePressure, 0.6, accuracy: 0.001); XCTAssertEqual(p.poseTiltX, -0.3, accuracy: 0.001)
        XCTAssertTrue(p.wetEdges); XCTAssertTrue(p.noise); XCTAssertTrue(p.airbrush)

        // Tip pixels: 40×30 centred in a 40×40 square, 16-bit samples scaled to 8 bits.
        guard let key = ink.tipKey, case .gray(let tip)? = set.tips[key]?.frames.first else { return XCTFail("no tip") }
        XCTAssertEqual(tip.width, 40); XCTAssertEqual(tip.height, 40)
        let src = Self.ring(40, 30)
        XCTAssertEqual(Self.px(tip, 20, 5 + 3), src[3 * 40 + 20])
        XCTAssertEqual(Self.px(tip, 0, 0), 0)
        guard let k3 = set.brushes[2].tipKey, case .gray(let t3)? = set.tips[k3]?.frames.first else { return XCTFail("no 16-bit tip") }
        XCTAssertEqual(t3.width, 24)
        XCTAssertEqual(Self.px(t3, 2 + 10, 12), Self.ring(20, 24)[12 * 20 + 10])
    }

    func testV2ComputedAndSampled() throws {
        let set = try ABRBrushReader.read(data: Self.abrV2(), name: "old")
        XCTAssertEqual(set.brushes.count, 2)
        XCTAssertNil(set.brushes[0].tipKey)
        XCTAssertEqual(set.brushes[0].params.size, 25)
        XCTAssertEqual(set.brushes[0].params.roundness, 0.5, accuracy: 0.001)
        XCTAssertEqual(set.brushes[0].params.angle, 45)
        XCTAssertEqual(set.brushes[0].params.hardness, 0.7, accuracy: 0.001)
        XCTAssertEqual(set.brushes[1].name, "Leaf")
        XCTAssertEqual(set.brushes[1].params.spacing, 0.15, accuracy: 0.001)
        // legacy API
        let tips = try ABRImporter.load(data: Self.abrV2())
        XCTAssertEqual(tips.count, 2)
        XCTAssertEqual(tips[1].tip.width, 12)
    }

    func testWriterRoundTrip() throws {
        let src = try ABRBrushReader.read(data: Self.abrV10(), name: "Kyle's Inkers")
        let (data, notes) = ABRWriter.write(src)
        XCTAssertTrue(notes.isEmpty, "\(notes)")
        let back = try ABRBrushReader.read(data: data, name: "again")
        XCTAssertEqual(back.brushes.map(\.name), src.brushes.map(\.name))
        XCTAssertEqual(back.patterns.count, 1)
        for (a, b) in zip(src.brushes, back.brushes) {
            var pa = a.params, pb = b.params
            pa.sanitize(); pb.sanitize()
            // pattern / dual tip ids are renamed by the writer
            pb.texturePatternID = pa.texturePatternID; pb.dualTipID = pa.dualTipID
            XCTAssertEqual(pa, pb, "settings of \(a.name)")
            XCTAssertEqual(a.tipKey == nil, b.tipKey == nil)
            if let ka = a.tipKey, let kb = b.tipKey, case .gray(let ta)? = src.tips[ka]?.frames.first, case .gray(let tb)? = back.tips[kb]?.frames.first {
                XCTAssertEqual(ta.width, tb.width); XCTAssertEqual(ta.height, tb.height)
                for y in 0..<ta.height { for x in 0..<ta.width where Self.px(ta, x, y) != Self.px(tb, x, y) { return XCTFail("tip pixel \(x),\(y) of \(a.name)") } }
            }
        }
        // The re-imported dual tip and texture are wired to the file's own tip and pattern.
        let ink = back.brushes[1].params
        XCTAssertNotNil(back.tips[ink.dualTipID])
        XCTAssertEqual(back.patterns.first?.id, ink.texturePatternID)
    }

    func testToolPresets() throws {
        let k = "12345678-1234-1234-1234-123456789abc"
        var samp = Data()
        samp.append(Self.sampleEntry(key: k, w: 10, h: 10, px: Self.ring(10, 10)))
        let brush = PSDDescriptor(classID: "brushPreset", [("Brsh", .object(PSDDescriptor(classID: "sampledBrush", [("Dmtr", .unitFloat(unit: "#Pxl", value: 33)), ("sampledData", .string(k))])))])
        let tool = PSDDescriptor(classID: "toolPreset", [
            ("Nm  ", .string("Inky Pen")),
            ("Opct", Self.prc(55)), ("flow", Self.prc(80)), ("Md  ", .enumerated(type: "BlnM", value: "Mltp")),
            ("Clr ", .object(PSDDescriptor(classID: "RGBC", [("Rd  ", .double(255)), ("Grn ", .double(0)), ("Bl  ", .double(0))]))),
            ("Brsh", .object(brush)),
        ])
        let other = PSDDescriptor(classID: "toolPreset", [("Nm  ", .string("Crop 4x5")), ("Wdth", .double(4))])
        let root = PSDDescriptor(classID: "null", [("Prst", .list([.object(tool), .object(other)]))])
        var d = Data()
        Self.u16(1, &d); Self.u16(0, &d); Self.u32(0, &d)
        d.append(Self.section("samp", samp))
        d.append(Self.section("desc", root.serializedVersioned()))
        let set = try TPLReader.read(data: d, name: "tools")
        XCTAssertEqual(set.brushes.count, 1)
        let b = try XCTUnwrap(set.brushes.first)
        XCTAssertEqual(b.name, "Inky Pen")
        XCTAssertEqual(b.params.size, 33)
        XCTAssertEqual(b.params.opacity, 0.55, accuracy: 0.001)
        XCTAssertEqual(b.params.blendMode, "multiply")
        XCTAssertTrue(b.includesToolSettings)
        XCTAssertEqual(b.color?.r ?? 0, 1, accuracy: 0.001)
    }

    func testCorruptAndTruncatedFilesNeverCrash() {
        let files = [Self.abrV10(), Self.abrV2(), ABRWriter.write((try? ABRBrushReader.read(data: Self.abrV10(), name: "x")) ?? ImportedBrushSet(name: "x")).data]
        var rng = SystemRandomNumberGenerator()
        _ = rng
        var seed: UInt64 = 0x1234_5678
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        var survived = 0
        for f in files {
            let bytes = [UInt8](f)
            // truncations
            let step = max(1, bytes.count / 300)
            for cut in stride(from: 0, to: bytes.count, by: step) {
                _ = try? ABRBrushReader.read(data: Data(bytes[0..<cut]), name: "t")
                _ = try? TPLReader.read(data: Data(bytes[0..<cut]), name: "t")
                survived += 1
            }
            // random corruption
            for _ in 0..<300 {
                var b = bytes
                for _ in 0..<(1 + Int(next() % 8)) { b[Int(next() % UInt64(b.count))] = UInt8(truncatingIfNeeded: next()) }
                _ = try? ABRBrushReader.read(data: Data(b), name: "c")
                survived += 1
            }
            // huge length fields
            for i in stride(from: 2, to: min(bytes.count - 4, 600), by: 3) {
                var b = bytes
                b[i] = 0xFF; b[i + 1] = 0xFF; b[i + 2] = 0xFF; b[i + 3] = 0xFF
                _ = try? ABRBrushReader.read(data: Data(b), name: "l")
                survived += 1
            }
        }
        XCTAssertGreaterThan(survived, 1000)
        XCTAssertThrowsError(try ABRBrushReader.read(data: Data([0, 3, 0, 0]), name: "v3"))
        XCTAssertThrowsError(try ABRBrushReader.read(data: Data(), name: "empty"))
    }

    func testPackBitsRoundTrip() throws {
        let rows: [[UInt8]] = [[], [1], [1, 1], [1, 2, 3], Array(repeating: 7, count: 300), (0..<300).map { UInt8($0 & 255) }, [5, 5, 5, 1, 2, 2, 9]]
        for r in rows {
            let packed = ABRBitmap.packBits(r[...])
            var reader = ABRByteReader(packed)
            var out = [UInt8](repeating: 0, count: r.count)
            try ABRBitmap.unpackBits(&reader, into: &out, offset: 0, count: r.count)
            XCTAssertEqual(out, r)
        }
    }
}
