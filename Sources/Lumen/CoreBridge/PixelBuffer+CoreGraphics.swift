import Foundation
import CoreGraphics
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Mac pixel storage: a CGContext-allocated bitmap, so Core Graphics draws straight into the buffer's pixels.
/// The CGContext has a flipped CTM so drawing uses top-left, y-down coordinates. Also holds the per-buffer
/// image / GPU caches (one object per buffer, created with it).
final class CGBitmapPixelStorage: PixelStorage {
    let context: CGContext
    let data: UnsafeMutableRawPointer
    let bytesPerRow: Int
    /// Keeps foreign memory alive when this wraps another storage (fallback path).
    private let owner: PixelStorage?

    var cachedImage: CGImage?
    var cachedImageVersion = -1
    var cachedCI: CIImage?
    var cachedCIVersion = -1
    var uploadedTileVersions: [Int] = []
    var texture: MTLTexture?

    /// New zeroed bitmap (the storage `PixelBuffer` uses in the app).
    init(width w: Int, height h: Int, format: PixelBuffer.Format) {
        let ctx: CGContext
        if format == .rgba {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        } else {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        }
        context = ctx
        data = ctx.data!
        bytesPerRow = ctx.bytesPerRow
        owner = nil
        memset(ctx.data!, 0, ctx.bytesPerRow * h)
        CGBitmapPixelStorage.flip(ctx, height: h)
    }

    /// A context drawing into memory owned by another storage (buffers created before `install()` ran).
    init(wrapping s: PixelStorage, width w: Int, height h: Int, format: PixelBuffer.Format) {
        let ctx = CGContext(data: s.data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: s.bytesPerRow,
                            space: format == .rgba ? sRGBSpace : graySpace,
                            bitmapInfo: format == .rgba ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.none.rawValue)!
        context = ctx
        data = s.data
        bytesPerRow = s.bytesPerRow
        owner = s
        CGBitmapPixelStorage.flip(ctx, height: h)
    }

    private static func flip(_ ctx: CGContext, height h: Int) {
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
    }

    /// Makes every new `PixelBuffer` CGContext-backed. Called first thing at launch.
    static func install() {
        PixelBuffer.makeStorage = { w, h, f in CGBitmapPixelStorage(width: w, height: h, format: f) }
    }
}

extension PixelBuffer {
    /// The CGContext-backed storage (and caches) of this buffer.
    @inline(__always) var cg: CGBitmapPixelStorage {
        let s = storage
        if ObjectIdentifier(type(of: s)) == ObjectIdentifier(CGBitmapPixelStorage.self) { return unsafeDowncast(s, to: CGBitmapPixelStorage.self) }
        return wrappedStorage()
    }

    private func wrappedStorage() -> CGBitmapPixelStorage {
        if let p = platform as? CGBitmapPixelStorage { return p }
        let w = CGBitmapPixelStorage(wrapping: storage, width: width, height: height, format: format)
        platform = w
        return w
    }

    /// Drawing context over the pixels (flipped CTM: top-left origin, y down).
    var context: CGContext { cg.context }

    convenience init(cgImage: CGImage, format: Format = .rgba) {
        self.init(width: cgImage.width, height: cgImage.height, format: format)
        drawImage(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// CIImage backed by a persistent GPU texture; only tiles changed since the last call are re-uploaded.
    private func tiledCIImage() -> CIImage {
        let ts = PixelBuffer.tileSize
        let c = cg
        if tileVersions.isEmpty { tileVersions = Array(repeating: 0, count: tilesX * tilesY) }
        if c.texture == nil {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format == .rgba ? .rgba8Unorm : .r8Unorm, width: width, height: height, mipmapped: false)
            td.usage = [.shaderRead]
            td.storageMode = .shared
            guard let t = RenderEngine.device.makeTexture(descriptor: td) else { return CIImage(cgImage: makeCGImage()) }
            c.texture = t
            c.uploadedTileVersions = Array(repeating: -1, count: tileVersions.count)
        }
        guard let tex = c.texture else { return CIImage(cgImage: makeCGImage()) }
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let i = ty * tilesX + tx
                if c.uploadedTileVersions[i] == tileVersions[i] { continue }
                let r = IRect(x: tx * ts, y: ty * ts, width: min(ts, width - tx * ts), height: min(ts, height - ty * ts))
                tex.replace(region: MTLRegionMake2D(r.x, r.y, r.width, r.height), mipmapLevel: 0,
                            withBytes: data + r.y * bytesPerRow + r.x * bytesPerPixel, bytesPerRow: bytesPerRow)
                c.uploadedTileVersions[i] = tileVersions[i]
            }
        }
        let opts: [CIImageOption: Any] = format == .rgba ? [.colorSpace: sRGBSpace] : [.colorSpace: NSNull()]
        guard var img = CIImage(mtlTexture: tex, options: opts) else { return CIImage(cgImage: makeCGImage()) }
        // Metal rows run top-down; CI is y-up.
        img = img.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
        if format == .gray {
            // expand single channel to gray RGB with opaque alpha, like CGImage-backed gray buffers
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                                                                   "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                   "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        return img
    }

    /// Immutable snapshot (copy-on-write).
    func makeCGImage() -> CGImage {
        let c = cg
        if let i = c.cachedImage, c.cachedImageVersion == version { return i }
        let img = c.context.makeImage()!
        c.cachedImage = img
        c.cachedImageVersion = version
        return img
    }

    /// No-copy image view over a sub-rect. Only valid until the buffer is next modified: draw it immediately.
    func unsafeImage(rect r: IRect? = nil) -> CGImage? {
        let rr = (r ?? bounds).intersection(bounds)
        if rr.isEmpty { return nil }
        let offset = rr.y * bytesPerRow + rr.x * bytesPerPixel
        let size = (rr.height - 1) * bytesPerRow + rr.width * bytesPerPixel
        guard let provider = CGDataProvider(dataInfo: nil, data: data + offset, size: size, releaseData: { _, _, _ in }) else { return nil }
        if format == .rgba {
            return CGImage(width: rr.width, height: rr.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                           space: sRGBSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        } else {
            return CGImage(width: rr.width, height: rr.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bytesPerRow,
                           space: graySpace, bitmapInfo: CGBitmapInfo(rawValue: 0),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Image mask (for CGContext.clip(to:mask:)) from a gray buffer.
    func makeMaskImage() -> CGImage { makeCGImage() }

    /// CIImage with extent (0,0,w,h) — CI y-up space. Place with `placed(atDocOrigin:canvasHeight:)`.
    var ciImage: CIImage {
        let c = cg
        if let i = c.cachedCI, c.cachedCIVersion == version { return i }
        let img = isTiled ? tiledCIImage() : CIImage(cgImage: makeCGImage())
        c.cachedCI = img
        c.cachedCIVersion = version
        return img
    }

    /// CI image placed at a doc origin; the same object is returned while unchanged (lets Core Image reuse cached work).
    func placed(at o: IPoint, space: CanvasSpace) -> CIImage {
        derived("placed-\(o.x)-\(o.y)-\(space.height)") { space.place(self, at: o) }
    }

    // MARK: Drawing helpers (y-down coordinates)

    /// Draws an image upright into `rect` (y-down doc coordinates) under the flipped CTM.
    func drawImage(_ image: CGImage, in rect: CGRect, alpha: CGFloat = 1, blend: CGBlendMode = .normal, clipRect: CGRect? = nil, interpolation: CGInterpolationQuality = .high) {
        let ctx = context
        ctx.saveGState()
        if let c = clipRect { ctx.clip(to: c) }
        ctx.setAlpha(alpha)
        ctx.setBlendMode(blend)
        ctx.interpolationQuality = interpolation
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Clip the context (y-down coordinates) to a gray mask image placed at rect. Call within save/restore.
    func clip(toMask mask: CGImage, in rect: CGRect) {
        let ctx = context
        // Undo the flip for the mask so it lands upright.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(origin: .zero, size: rect.size), mask: mask)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.minX, y: -rect.maxY)
    }

    // MARK: Encoding

    func pngData() -> Data? {
        let img = makeCGImage()
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return d as Data
    }
}
