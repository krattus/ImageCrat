import Foundation
import XCTest
import ImageCratCore

/// Pure pixel algorithms on tiny images (deterministic output, no platform code).
final class AlgorithmTests: XCTestCase {
    /// 48×32 horizontal ramp with vertical stripes, opaque.
    private func stripes() -> PixelBuffer {
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

    private func bytes(_ b: PixelBuffer) -> [UInt8] {
        var out: [UInt8] = []
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<b.height { for i in 0..<(b.width * b.bytesPerPixel) { out.append(p[y * b.bytesPerRow + i]) } }
        return out
    }

    func testInpaintFillsHoleDeterministically() {
        let img = stripes()
        let hole = PixelBuffer(width: 48, height: 32, format: .gray)
        let hp = hole.data.assumingMemoryBound(to: UInt8.self)
        for y in 12..<20 { for x in 20..<28 { hp[y * hole.bytesPerRow + x] = 255 } }
        // punch the hole so leftovers would show
        let ip = img.data.assumingMemoryBound(to: UInt8.self)
        for y in 12..<20 { for x in 20..<28 { for c in 0..<4 { ip[y * img.bytesPerRow + x * 4 + c] = 0 } } }

        let a = Inpainter.inpaint(img, hole: hole)
        let b = Inpainter.inpaint(img, hole: hole)
        XCTAssertEqual(bytes(a), bytes(b), "same input, same output")
        for y in 0..<32 {
            for x in 0..<48 {
                let inHole = (12..<20).contains(y) && (20..<28).contains(x)
                if inHole {
                    XCTAssertEqual(a.alpha(x, y), 255, "hole pixel (\(x),\(y)) filled with opaque content")
                } else {
                    XCTAssertTrue(a.pixel(x, y) == img.pixel(x, y), "pixels outside the hole are unchanged")
                }
            }
        }
        // the fill reuses the stripe colours of the surroundings
        let reds = Set((12..<20).flatMap { y in (20..<28).map { x in a.pixel(x, y).0 } })
        XCTAssertTrue(reds.contains { $0 > 150 } && reds.contains { $0 < 100 }, "both stripe colours appear in the fill: \(reds.sorted())")
    }

    func testContentAwareScaleSizeAndDeterminism() {
        let img = stripes()
        let a = ContentAwareScale.scale(img, newWidth: 36, newHeight: 32)
        let b = ContentAwareScale.scale(img, newWidth: 36, newHeight: 32)
        XCTAssertEqual(a.width, 36); XCTAssertEqual(a.height, 32)
        XCTAssertEqual(bytes(a), bytes(b))
        XCTAssertEqual(a.opaqueBounds(), IRect(x: 0, y: 0, width: 36, height: 32))
        let t = ContentAwareScale.transpose(img)
        XCTAssertEqual(t.width, 32); XCTAssertEqual(t.height, 48)
        XCTAssertTrue(t.pixel(5, 7) == img.pixel(7, 5))
    }
}
