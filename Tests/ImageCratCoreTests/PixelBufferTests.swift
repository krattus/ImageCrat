import Foundation
import XCTest
import ImageCratCore

/// Pixel storage, pixel access and format conversion. Uses the portable heap storage (no platform hook installed).
final class PixelBufferTests: XCTestCase {
    /// Writes one premultiplied RGBA pixel straight into the buffer memory.
    private func put(_ b: PixelBuffer, _ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ bl: UInt8, _ a: UInt8) {
        let p = b.data.assumingMemoryBound(to: UInt8.self) + b.offset(x, y)
        p[0] = r; p[1] = g; p[2] = bl; p[3] = a
    }

    func testNewBuffersAreZeroedAndRowsAligned() {
        let b = PixelBuffer(width: 5, height: 3)
        XCTAssertEqual(b.format, .rgba)
        XCTAssertEqual(b.bytesPerPixel, 4)
        XCTAssertGreaterThanOrEqual(b.bytesPerRow, 5 * 4)
        XCTAssertEqual(b.bytesPerRow % 32, 0, "rows are 32-byte aligned like CoreGraphics bitmaps")
        for y in 0..<3 { for x in 0..<5 { XCTAssertTrue(b.pixel(x, y) == (0, 0, 0, 0)) } }
        XCTAssertTrue(b.isFullyTransparent)
        XCTAssertNil(b.opaqueBounds())
        // dimensions are clamped to at least 1
        let z = PixelBuffer(width: 0, height: -4, format: .gray)
        XCTAssertEqual(z.width, 1); XCTAssertEqual(z.height, 1)
    }

    func testPixelAccessUnpremultipliesAndBoundsChecks() {
        let b = PixelBuffer(width: 4, height: 4)
        put(b, 1, 2, 100, 50, 25, 128)   // premultiplied, half alpha
        put(b, 3, 3, 10, 20, 30, 255)
        let p = b.pixel(1, 2)
        XCTAssertEqual(p.3, 128)
        XCTAssertEqual(p.0, UInt8(min(255, 100.0 * 255 / 128)))
        XCTAssertEqual(p.1, UInt8(min(255, 50.0 * 255 / 128)))
        XCTAssertEqual(p.2, UInt8(min(255, 25.0 * 255 / 128)))
        XCTAssertTrue(b.pixel(3, 3) == (10, 20, 30, 255))
        XCTAssertEqual(b.alpha(1, 2), 128)
        XCTAssertTrue(b.pixel(-1, 0) == (0, 0, 0, 0))
        XCTAssertTrue(b.pixel(4, 0) == (0, 0, 0, 0))
        XCTAssertEqual(b.alpha(0, 9), 0)
        XCTAssertEqual(b.opaqueBounds(), IRect(x: 1, y: 2, width: 3, height: 2))
        XCTAssertEqual(b.opaqueBounds(threshold: 200), IRect(x: 3, y: 3, width: 1, height: 1))
    }

    func testFormatConversion() {
        let b = PixelBuffer(width: 3, height: 1)
        put(b, 0, 0, 255, 0, 0, 255)
        put(b, 1, 0, 0, 255, 0, 255)
        put(b, 2, 0, 0, 0, 128, 128)
        let lum = b.toGray()
        XCTAssertEqual(lum.format, .gray)
        XCTAssertEqual(lum.bytesPerPixel, 1)
        XCTAssertEqual(lum.alpha(0, 0), UInt8((255 * 77) >> 8))
        XCTAssertEqual(lum.alpha(1, 0), UInt8((255 * 150) >> 8))
        XCTAssertEqual(lum.alpha(2, 0), UInt8((128 * 29) >> 8))
        XCTAssertTrue(lum.pixel(0, 0) == (76, 76, 76, 255), "gray pixels read back as opaque gray")
        let a = b.toGray(useAlpha: true)
        XCTAssertEqual([a.alpha(0, 0), a.alpha(1, 0), a.alpha(2, 0)], [255, 255, 128])
        let rgba = a.toRGBA()
        XCTAssertEqual(rgba.format, .rgba)
        XCTAssertTrue(rgba.pixel(2, 0) == (128, 128, 128, 255))
        let filled = PixelBuffer(width: 2, height: 2, gray: 200)
        XCTAssertEqual(filled.alpha(1, 1), 200)
    }

    func testCopyCropAndCopyPixels() {
        let b = PixelBuffer(width: 6, height: 4)
        put(b, 4, 1, 9, 8, 7, 255)
        let c = b.copy()
        put(b, 4, 1, 0, 0, 0, 0)
        XCTAssertTrue(c.pixel(4, 1) == (9, 8, 7, 255), "copy owns its pixels")
        let cr = c.cropped(to: IRect(x: 3, y: 1, width: 2, height: 2))
        XCTAssertEqual(cr.width, 2); XCTAssertEqual(cr.height, 2)
        XCTAssertTrue(cr.pixel(1, 0) == (9, 8, 7, 255))
        let dst = PixelBuffer(width: 6, height: 4)
        dst.copyPixels(from: cr, at: IPoint(x: 0, y: 2))
        XCTAssertTrue(dst.pixel(1, 2) == (9, 8, 7, 255))
        let v = dst.version
        dst.markDirty(IRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(dst.version, v + 1)
    }

    func testDerivedCacheFollowsVersion() {
        let b = PixelBuffer(width: 2, height: 2)
        var calls = 0
        _ = b.derived("k") { () -> Int in calls += 1; return 1 }
        _ = b.derived("k") { () -> Int in calls += 1; return 1 }
        XCTAssertEqual(calls, 1)
        b.markDirty()
        _ = b.derived("k") { () -> Int in calls += 1; return 1 }
        XCTAssertEqual(calls, 2)
    }

    func testCodableRoundTripKeepsPixels() throws {
        let b = PixelBuffer(width: 7, height: 5)
        for y in 0..<5 { for x in 0..<7 { put(b, x, y, UInt8(x * 30), UInt8(y * 50), UInt8((x + y) * 10), 255) } }
        let data = try PropertyListEncoder().encode([b])
        let back = try PropertyListDecoder().decode([PixelBuffer].self, from: data)[0]
        XCTAssertEqual(back.width, 7); XCTAssertEqual(back.height, 5); XCTAssertEqual(back.format, .rgba)
        for y in 0..<5 { for x in 0..<7 { XCTAssertTrue(back.pixel(x, y) == b.pixel(x, y)) } }
    }

    func testCustomStorageHook() {
        final class Tracking: PixelStorage {
            let inner: HeapPixelStorage
            var data: UnsafeMutableRawPointer { inner.data }
            var bytesPerRow: Int { inner.bytesPerRow }
            init(_ w: Int, _ h: Int, _ f: PixelBuffer.Format) { inner = HeapPixelStorage(width: w, height: h, bytesPerPixel: f == .rgba ? 4 : 1) }
        }
        let saved = PixelBuffer.makeStorage
        defer { PixelBuffer.makeStorage = saved }
        PixelBuffer.makeStorage = { w, h, f in Tracking(w, h, f) }
        let b = PixelBuffer(width: 3, height: 3, format: .gray)
        XCTAssertTrue(b.storage is Tracking)
        XCTAssertEqual(b.data, (b.storage as! Tracking).inner.data)
    }
}
