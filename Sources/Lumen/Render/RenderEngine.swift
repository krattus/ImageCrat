import Foundation
import CoreImage
import Metal
import ImageCratCore

enum RenderEngine {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    static let commandQueue: MTLCommandQueue = device.makeCommandQueue()!

    /// Shared context. Working space is gamma-encoded sRGB so blend modes behave like Photoshop.
    static let context: CIContext = CIContext(mtlDevice: device, options: [
        .workingColorSpace: sRGBSpace,
        .outputColorSpace: sRGBSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
        .name: "Lumen",
    ])

    /// Context for CPU readbacks (same GPU, separate cache).
    static let readbackContext: CIContext = CIContext(mtlDevice: device, options: [
        .workingColorSpace: sRGBSpace,
        .outputColorSpace: sRGBSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    /// Renders a CI-space rect into a new CGImage.
    static func cgImage(_ image: CIImage, rect: CGRect) -> CGImage? {
        readbackContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: sRGBSpace)
    }

    /// Renders `image` (CI space) into `buffer`, where the buffer's top-left sits at doc point `origin`.
    static func render(_ image: CIImage, into buffer: PixelBuffer, docOrigin origin: IPoint, space: CanvasSpace) {
        let ciRect = space.ciRect(IRect(x: origin.x, y: origin.y, width: buffer.width, height: buffer.height))
        if buffer.format == .rgba {
            let bg = CIImage.clearImage.cropped(to: ciRect)
            readbackContext.render(image.composited(over: bg), toBitmap: buffer.data, rowBytes: buffer.bytesPerRow, bounds: ciRect,
                                   format: .RGBA8, colorSpace: sRGBSpace)
        } else {
            let bg = CIImage(color: .black).cropped(to: ciRect)
            readbackContext.render(image.composited(over: bg), toBitmap: buffer.data, rowBytes: buffer.bytesPerRow, bounds: ciRect,
                                   format: .L8, colorSpace: graySpace)
        }
        buffer.markDirty()
    }

    /// Renders into a freshly allocated buffer covering doc rect `r`.
    static func renderBuffer(_ image: CIImage, docRect r: IRect, space: CanvasSpace, format: PixelBuffer.Format = .rgba) -> PixelBuffer {
        let b = PixelBuffer(width: max(1, r.width), height: max(1, r.height), format: format)
        render(image, into: b, docOrigin: r.origin, space: space)
        return b
    }
}

/// Small cache for rasterized vector/text/smart content keyed by layer id + equatable content.
final class RenderCache<Key> {
    private var entries: [UUID: (Key, CIImage)] = [:]
    private let isEqual: (Key, Key) -> Bool

    init(isEqual: @escaping (Key, Key) -> Bool) { self.isEqual = isEqual }

    func get(_ id: UUID, _ key: Key, make: () -> CIImage) -> CIImage {
        if let e = entries[id], isEqual(e.0, key) { return e.1 }
        let img = make()
        entries[id] = (key, img)
        return img
    }

    func removeAll() { entries.removeAll() }
    /// Drops entries of layers that no open document has (closed documents' rasterized content).
    func prune(keeping ids: Set<UUID>) { entries = entries.filter { ids.contains($0.key) } }
    var ids: Set<UUID> { Set(entries.keys) }
}

extension RenderCache where Key: Equatable {
    convenience init() { self.init(isEqual: ==) }
}
