import Foundation
import XCTest
import ImageCratCore

/// Byte-level PSD pieces: PackBits rows, layer-style descriptors and adjustment-layer blocks, written and read back.
final class PSDByteTests: XCTestCase {
    private struct Bytes: PSDByteSource { let bytes: [UInt8] }

    func testPackBitsRoundTrip() throws {
        let row: [UInt8] = [7, 7, 7, 7, 7, 1, 2, 3, 3, 9] + Array(repeating: 200, count: 300) + (0..<140).map { UInt8($0 % 251) }
        let packed = row.withUnsafeBufferPointer { PackBits.encode($0) }
        XCTAssertLessThan(packed.count, row.count)
        var r = BinaryReader(Data(packed))
        var out = [UInt8](repeating: 0, count: row.count)
        try out.withUnsafeMutableBufferPointer { try PackBits.decode(&r, into: $0.baseAddress!, count: row.count, byteLength: packed.count) }
        XCTAssertEqual(out, row)
    }

    func testBinaryWriterReader() throws {
        var w = BinaryWriter()
        w.u16(0xBEEF); w.i16(-2); w.u32(0xDEAD_BEEF); w.ascii("8BPS"); w.u64(1 << 40)
        var r = BinaryReader(w.data)
        XCTAssertEqual(try r.u16(), 0xBEEF); XCTAssertEqual(try r.i16(), -2); XCTAssertEqual(try r.u32(), 0xDEAD_BEEF)
        XCTAssertEqual(try r.ascii(4), "8BPS"); XCTAssertEqual(try r.u64(), 1 << 40)
        XCTAssertThrowsError(try r.u8(), "reading past the end throws instead of trapping")
        var c = PSDCursor(Array(w.data))
        XCTAssertEqual(try c.u16(), 0xBEEF)
        XCTAssertEqual(try c.i16(), -2)
        XCTAssertThrowsError(try c.skip(1000))
        XCTAssertEqual(BlendMode(psdKey: BlendMode.colorDodge.psdKey), .colorDodge)
        XCTAssertEqual(BlendMode(psdKey: "????"), .normal)
    }

    func testLayerStyleDescriptorRoundTrip() throws {
        var fx = LayerEffects()
        fx.dropShadow.enabled = true; fx.dropShadow.distance = 12; fx.dropShadow.size = 9; fx.dropShadow.color = RGBA(hex: "112233")!
        fx.stroke.enabled = true; fx.stroke.size = 4
        fx.bevel.enabled = true; fx.bevel.size = 7
        let payload = PSDLayerStyle.encode(fx)
        let back = try XCTUnwrap(PSDLayerStyle.decode(payload))
        XCTAssertTrue(back.dropShadow.enabled && back.stroke.enabled && back.bevel.enabled)
        XCTAssertFalse(back.innerGlow.enabled)
        XCTAssertEqual(back.dropShadow.distance, 12, accuracy: 1e-6)
        XCTAssertEqual(back.dropShadow.size, 9, accuracy: 1e-6)
        XCTAssertEqual(back.dropShadow.color.hex, "112233")
        XCTAssertEqual(back.stroke.size, 4, accuracy: 1e-6)
        XCTAssertEqual(back.bevel.size, 7, accuracy: 1e-6)
    }

    /// Encodes `s` as Photoshop adjustment blocks, lays them out in a byte array and parses them back.
    private func roundTrip(_ s: AdjustmentSettings) throws -> AdjustmentSettings {
        let enc = PSDExportAdjust.encode(s)
        let blocks = try XCTUnwrap(enc.blocks, "\(s.kind) has a Photoshop block")
        var bytes: [UInt8] = []
        var rec = PSDRecord()
        for (key, data) in blocks {
            rec.blocks.append(PSDBlock(key: key, range: bytes.count..<(bytes.count + data.count)))
            bytes += Array(data)
        }
        let key = try XCTUnwrap(PSDAdjust.key(of: rec))
        guard case .ok(let back, _) = PSDAdjust.settings(key, rec, Bytes(bytes: bytes)) else { XCTFail("\(s.kind) did not parse"); return s }
        return back
    }

    func testAdjustmentBlocksRoundTrip() throws {
        var sel = AdjustmentSettings(kind: .selectiveColor)
        sel.selective[0] = SelectiveColorEntry(cyan: -30, magenta: 10, yellow: 20, black: 5)
        sel.selective[7].black = 15
        sel.selectiveAbsolute = true
        let s2 = try roundTrip(sel)
        XCTAssertEqual(s2.kind, .selectiveColor)
        XCTAssertEqual(s2.selective, sel.selective)
        XCTAssertTrue(s2.selectiveAbsolute)

        var lv = AdjustmentSettings(kind: .levels)
        lv.levels[0] = LevelsChannel(inBlack: 12, inWhite: 240, gamma: 1.3, outBlack: 5, outWhite: 250)
        let l2 = try roundTrip(lv)
        XCTAssertEqual(l2.levels[0].inBlack, 12); XCTAssertEqual(l2.levels[0].inWhite, 240)
        XCTAssertEqual(l2.levels[0].gamma, 1.3, accuracy: 0.01)

        var bc = AdjustmentSettings(kind: .brightnessContrast)
        bc.brightness = 40; bc.contrast = -20
        let b2 = try roundTrip(bc)
        XCTAssertEqual(b2.brightness, 40, accuracy: 0.5); XCTAssertEqual(b2.contrast, -20, accuracy: 0.5)

        var cb = AdjustmentSettings(kind: .colorBalance)
        cb.midtones = ToneTriple(cyanRed: 30, magentaGreen: -10, yellowBlue: 5)
        XCTAssertEqual(try roundTrip(cb).midtones, cb.midtones)

        var post = AdjustmentSettings(kind: .posterize)
        post.posterizeLevels = 6
        XCTAssertEqual(try roundTrip(post).posterizeLevels, 6)
    }
}
