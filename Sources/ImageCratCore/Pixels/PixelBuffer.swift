import Foundation

/// Memory behind a `PixelBuffer`. The platform layer may supply its own (the Mac app uses CGContext-backed bitmaps so
/// Core Graphics can draw straight into the pixels); the default is a plain zeroed heap allocation.
package protocol PixelStorage: AnyObject {
    /// First byte of row 0 (the top row). Stays valid for the storage's lifetime.
    var data: UnsafeMutableRawPointer { get }
    var bytesPerRow: Int { get }
}

/// Portable storage: a zero-filled, 64-byte aligned heap block with 32-byte aligned rows.
package final class HeapPixelStorage: PixelStorage {
    package let data: UnsafeMutableRawPointer
    package let bytesPerRow: Int
    private let byteCount: Int

    package init(width: Int, height: Int, bytesPerPixel: Int) {
        bytesPerRow = (width * bytesPerPixel + 31) & ~31
        byteCount = bytesPerRow * height
        data = UnsafeMutableRawPointer.allocate(byteCount: max(1, byteCount), alignment: 64)
        memset(data, 0, byteCount)
    }

    deinit { data.deallocate() }
}

/// A mutable 8-bit bitmap. RGBA buffers are premultiplied (RGBA order), gray buffers are single-channel.
/// Memory row 0 is the top row.
///
/// Buffers referenced by history must be treated as immutable: clone before modifying.
package final class PixelBuffer: Codable {
    package enum Format: Int, Codable { case rgba, gray }

    package let width: Int
    package let height: Int
    package let format: Format
    /// Owns the pixel memory (and, on the Mac, the CGContext drawing into it).
    package let storage: PixelStorage
    package let bytesPerRow: Int
    package let data: UnsafeMutableRawPointer
    @inlinable package var bytesPerPixel: Int { format == .rgba ? 4 : 1 }

    /// Creates the storage for new buffers (width, height, format; dimensions are already clamped to >= 1).
    /// The Mac app installs a CGContext-backed factory at launch; the memory must start zeroed.
    nonisolated(unsafe) package static var makeStorage: (Int, Int, Format) -> PixelStorage = { w, h, f in
        HeapPixelStorage(width: w, height: h, bytesPerPixel: f == .rgba ? 4 : 1)
    }

    package private(set) var version: Int = 0
    /// Per-buffer caches owned by the platform layer (images, GPU textures); never touched by the core.
    package var platform: AnyObject?
    /// Arbitrary per-version derived data cache (bounds, outline paths...).
    private var derivedCache: [String: (Int, Any)] = [:]

    package init(width: Int, height: Int, format: Format = .rgba) {
        let w = max(1, width), h = max(1, height)
        self.width = w
        self.height = h
        self.format = format
        let s = PixelBuffer.makeStorage(w, h, format)
        self.storage = s
        self.bytesPerRow = s.bytesPerRow
        self.data = s.data
    }

    /// Filled gray buffer.
    package convenience init(width: Int, height: Int, gray: UInt8) {
        self.init(width: width, height: height, format: .gray)
        if gray != 0 { memset(data, Int32(gray), bytesPerRow * height) }
    }

    package func copy() -> PixelBuffer {
        let n = PixelBuffer(width: width, height: height, format: format)
        if n.bytesPerRow == bytesPerRow {
            memcpy(n.data, data, bytesPerRow * height)
        } else {
            let rb = width * bytesPerPixel
            for y in 0..<height { memcpy(n.data + y * n.bytesPerRow, data + y * bytesPerRow, rb) }
        }
        return n
    }

    @inlinable package var bounds: IRect { IRect(x: 0, y: 0, width: width, height: height) }

    package func markDirty() {
        version &+= 1
        if !tileVersions.isEmpty { for i in tileVersions.indices { tileVersions[i] &+= 1 } }
    }

    /// Marks only `r` as changed: large buffers then re-upload just the affected tiles to the GPU.
    package func markDirty(_ r: IRect) {
        version &+= 1
        guard isTiled, !tileVersions.isEmpty else { return }
        let rr = r.intersection(bounds)
        if rr.isEmpty { return }
        let ts = PixelBuffer.tileSize
        for ty in (rr.minY / ts)...((rr.maxY - 1) / ts) {
            for tx in (rr.minX / ts)...((rr.maxX - 1) / ts) { tileVersions[ty * tilesX + tx] &+= 1 }
        }
    }

    // MARK: Tiles (large buffers)

    package static let tileSize = 512
    package static let tiledThreshold = ProcessInfo.processInfo.environment["LUMEN_TILE_THRESHOLD"].flatMap { Int($0) } ?? 2500 * 2500
    package var isTiled: Bool { width * height >= PixelBuffer.tiledThreshold }
    package var tilesX: Int { (width + PixelBuffer.tileSize - 1) / PixelBuffer.tileSize }
    package var tilesY: Int { (height + PixelBuffer.tileSize - 1) / PixelBuffer.tileSize }
    /// Per-tile change counters (empty until the platform layer starts tracking tiles for GPU upload).
    package var tileVersions: [Int] = []

    package func derived<T>(_ key: String, _ make: () -> T) -> T {
        if let (v, val) = derivedCache[key], v == version, let t = val as? T { return t }
        let t = make()
        derivedCache[key] = (version, t)
        return t
    }

    // MARK: Pixel access

    @inlinable @inline(__always) package func offset(_ x: Int, _ y: Int) -> Int { y * bytesPerRow + x * bytesPerPixel }

    /// Returns non-premultiplied RGBA 0-255 (gray buffers return gray in rgb and 255 alpha).
    @inlinable package func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let p = data.assumingMemoryBound(to: UInt8.self) + offset(x, y)
        if format == .gray { return (p[0], p[0], p[0], 255) }
        let a = p[3]
        if a == 0 { return (0, 0, 0, 0) }
        if a == 255 { return (p[0], p[1], p[2], 255) }
        let fa = Double(a)
        return (UInt8(min(255, Double(p[0]) * 255 / fa)), UInt8(min(255, Double(p[1]) * 255 / fa)), UInt8(min(255, Double(p[2]) * 255 / fa)), a)
    }

    @inlinable package func alpha(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        let p = data.assumingMemoryBound(to: UInt8.self) + offset(x, y)
        return format == .gray ? p[0] : p[3]
    }

    /// Copies a rect of pixels from another buffer of the same format (same coordinate space).
    package func copyPixels(from src: PixelBuffer, rect: IRect) {
        let r = rect.intersection(bounds).intersection(src.bounds)
        if r.isEmpty { return }
        let rb = r.width * bytesPerPixel
        for y in r.minY..<r.maxY {
            memcpy(data + offset(r.x, y), src.data + src.offset(r.x, y), rb)
        }
    }

    /// Copies pixels from `src` placed at `srcOrigin` (relative to self) into self.
    package func copyPixels(from src: PixelBuffer, at srcOrigin: IPoint) {
        let target = IRect(x: srcOrigin.x, y: srcOrigin.y, width: src.width, height: src.height).intersection(bounds)
        if target.isEmpty { return }
        let rb = target.width * bytesPerPixel
        for y in target.minY..<target.maxY {
            memcpy(data + offset(target.x, y), src.data + src.offset(target.x - srcOrigin.x, y - srcOrigin.y), rb)
        }
    }

    /// Bounding box of non-transparent (alpha > threshold) pixels, or nil if empty.
    package func opaqueBounds(threshold: UInt8 = 0) -> IRect? {
        derived("opaqueBounds\(threshold)") { () -> IRect? in
            let p = data.assumingMemoryBound(to: UInt8.self)
            let bpp = bytesPerPixel
            let ai = format == .rgba ? 3 : 0
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            for y in 0..<height {
                let row = p + y * bytesPerRow
                var rowHas = false
                var rx0 = -1, rx1 = -1
                for x in 0..<width where row[x * bpp + ai] > threshold {
                    if rx0 < 0 { rx0 = x }
                    rx1 = x
                    rowHas = true
                }
                if rowHas {
                    y0 = min(y0, y); y1 = y
                    x0 = min(x0, rx0); x1 = max(x1, rx1)
                }
            }
            if x1 < 0 { return nil }
            return IRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
        }
    }

    package var isFullyTransparent: Bool { opaqueBounds() == nil }

    /// Returns a cropped copy.
    package func cropped(to r: IRect) -> PixelBuffer {
        let n = PixelBuffer(width: max(1, r.width), height: max(1, r.height), format: format)
        n.copyPixels(from: self, at: IPoint(x: -r.x, y: -r.y))
        return n
    }

    // MARK: Encoding

    private enum CodingKeys: String, CodingKey { case width, height, format, bytes }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(format, forKey: .format)
        // Pack rows tightly, then compress.
        let rb = width * bytesPerPixel
        var raw = Data(count: rb * height)
        raw.withUnsafeMutableBytes { dst in
            let base = dst.baseAddress!
            for y in 0..<height { memcpy(base + y * rb, data + y * bytesPerRow, rb) }
        }
        try c.encode(PixelBuffer.compress(raw), forKey: .bytes)
    }

    package convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try c.decode(Int.self, forKey: .width)
        let h = try c.decode(Int.self, forKey: .height)
        let f = try c.decode(Format.self, forKey: .format)
        let packed = try c.decode(Data.self, forKey: .bytes)
        self.init(width: w, height: h, format: f)
        let rb = w * bytesPerPixel
        let raw = PixelBuffer.decompress(packed)
        guard raw.count >= rb * h else { return }
        raw.withUnsafeBytes { src in
            let base = src.baseAddress!
            for y in 0..<h { memcpy(data + y * bytesPerRow, base + y * rb, rb) }
        }
    }

    /// LZFSE (what documents store). NOTE: swift-corelibs-foundation has no `NSData.compressed(using:)`; until a portable
    /// LZFSE codec is added, other platforms write raw rows and cannot read LZFSE-packed pixels from Mac documents.
    package static func compress(_ raw: Data) -> Data {
        #if canImport(Darwin)
        return (try? (raw as NSData).compressed(using: .lzfse) as Data) ?? raw
        #else
        return raw
        #endif
    }

    package static func decompress(_ packed: Data) -> Data {
        #if canImport(Darwin)
        return (try? (packed as NSData).decompressed(using: .lzfse) as Data) ?? packed
        #else
        return packed
        #endif
    }
}

extension PixelBuffer {
    /// Convert an RGBA buffer into a gray buffer using luminance (for masks).
    package func toGray(useAlpha: Bool = false) -> PixelBuffer {
        if format == .gray { return copy() }
        let g = PixelBuffer(width: width, height: height, format: .gray)
        let s = data.assumingMemoryBound(to: UInt8.self)
        let d = g.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let sr = s + y * bytesPerRow, dr = d + y * g.bytesPerRow
            for x in 0..<width {
                let i = x * 4
                if useAlpha {
                    dr[x] = sr[i + 3]
                } else {
                    // premultiplied luminance over black
                    dr[x] = UInt8((UInt32(sr[i]) * 77 + UInt32(sr[i + 1]) * 150 + UInt32(sr[i + 2]) * 29) >> 8)
                }
            }
        }
        return g
    }

    /// Gray buffer -> RGBA (opaque gray).
    package func toRGBA() -> PixelBuffer {
        if format == .rgba { return copy() }
        let r = PixelBuffer(width: width, height: height, format: .rgba)
        let s = data.assumingMemoryBound(to: UInt8.self)
        let d = r.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let sr = s + y * bytesPerRow, dr = d + y * r.bytesPerRow
            for x in 0..<width {
                let v = sr[x]
                dr[x * 4] = v; dr[x * 4 + 1] = v; dr[x * 4 + 2] = v; dr[x * 4 + 3] = 255
            }
        }
        return r
    }
}
