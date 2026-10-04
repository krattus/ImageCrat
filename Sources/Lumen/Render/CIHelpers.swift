import CoreImage
import CoreGraphics
import ImageCratCore

/// Conversions between document space (top-left origin, y down) and Core Image space (bottom-left, y up).
struct CanvasSpace {
    let width: Int
    let height: Int

    var ciCanvas: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    func ciRect(_ r: IRect) -> CGRect { CGRect(x: r.x, y: height - r.y - r.height, width: r.width, height: r.height) }
    func ciRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height) }
    func docRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height) }
    func ciPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: CGFloat(height) - p.y) }
    func docPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: CGFloat(height) - p.y) }

    /// Flip transform (self-inverse).
    var flip: CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)) }

    /// Converts a doc-space affine transform to CI space.
    func ciTransform(_ t: CGAffineTransform) -> CGAffineTransform {
        flip.concatenating(t).concatenating(flip)
    }

    /// Places a buffer image (extent 0,0,w,h) at a doc origin.
    func place(_ img: CIImage, docOrigin o: IPoint, size: (Int, Int)) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: CGFloat(o.x), y: CGFloat(height - o.y - size.1)))
    }

    func place(_ buffer: PixelBuffer, at o: IPoint) -> CIImage {
        place(buffer.ciImage, docOrigin: o, size: (buffer.width, buffer.height))
    }
}

extension CIImage {
    static let clearImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))

    static func color(_ c: RGBA, _ rect: CGRect) -> CIImage { CIImage(color: c.ciColor).cropped(to: rect) }

    func translated(_ dx: CGFloat, _ dy: CGFloat) -> CIImage { transformed(by: CGAffineTransform(translationX: dx, y: dy)) }

    /// Multiplies alpha (and premultiplied color) by `a`.
    func withOpacity(_ a: Double) -> CIImage {
        if a >= 0.9999 { return self }
        if a <= 0.0001 { return CIImage.clearImage.cropped(to: extent) }
        return applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a)),
        ])
    }

    /// Gaussian blur that doesn't darken edges of the given region: clamp, blur, crop.
    func blurred(_ radius: Double, clampTo rect: CGRect? = nil) -> CIImage {
        if radius < 0.05 { return self }
        let r = rect ?? extent
        if r.isInfinite { return applyingGaussianBlur(sigma: radius) }
        return clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: r)
    }

    /// Transparent-border blur (grows extent).
    func softBlurred(_ radius: Double) -> CIImage {
        if radius < 0.05 { return self }
        let ext = extent
        let grown = ext.insetBy(dx: -CGFloat(radius * 3), dy: -CGFloat(radius * 3))
        return self.composited(over: CIImage.clearImage.cropped(to: grown)).applyingGaussianBlur(sigma: radius).cropped(to: grown)
    }

    /// Solid `color` using this image's alpha.
    func colorized(_ c: RGBA) -> CIImage {
        let col = CIImage(color: c.withAlpha(1).ciColor).cropped(to: extent)
        let tinted = col.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.clearImage.cropped(to: extent),
            kCIInputMaskImageKey: self,
        ])
        return tinted.withOpacity(c.a)
    }

    /// Alpha channel as opaque grayscale.
    var alphaAsGray: CIImage {
        applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Luminance (gray) to alpha of white.
    var grayAsAlpha: CIImage { applyingFilter("CIMaskToAlpha") }

    /// Keep this image only where `mask` (grayscale) is white.
    func masked(byGray mask: CIImage) -> CIImage {
        applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.clearImage.cropped(to: extent),
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Keep this image only where `mask`'s alpha is set.
    func masked(byAlphaOf mask: CIImage) -> CIImage {
        applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.clearImage.cropped(to: extent),
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Mix between self (where mask white) and `other`.
    func mixed(with other: CIImage, mask: CIImage) -> CIImage {
        applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: other,
            kCIInputMaskImageKey: mask,
        ])
    }

    func inverted() -> CIImage { applyingFilter("CIColorInvert") }

    /// Blend self (source) over backdrop with a Photoshop blend mode.
    func blended(over backdrop: CIImage, mode: BlendMode) -> CIImage {
        switch mode {
        case .normal, .passThrough:
            return composited(over: backdrop)
        case .dissolve:
            return Kernels.dissolve(self, backdrop)
        case .hardMix:
            return Kernels.customBlend(self, backdrop, kernel: Kernels.hardMix)
        case .darkerColor:
            return Kernels.customBlend(self, backdrop, kernel: Kernels.darkerColor)
        case .lighterColor:
            return Kernels.customBlend(self, backdrop, kernel: Kernels.lighterColor)
        default:
            guard let name = mode.ciFilterName else { return composited(over: backdrop) }
            return applyingFilter(name, parameters: [kCIInputBackgroundImageKey: backdrop])
        }
    }

    /// Morphological dilation of alpha (radius px) — for spreads and strokes.
    func dilatedAlpha(_ r: Double) -> CIImage {
        if r < 0.5 { return self }
        let grown = extent.insetBy(dx: -CGFloat(r + 2), dy: -CGFloat(r + 2))
        return composited(over: CIImage.clearImage.cropped(to: grown))
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: grown)
    }

    func erodedAlpha(_ r: Double) -> CIImage {
        if r < 0.5 { return self }
        return applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: extent)
    }
}

extension CGRect {
    var ciVector: CIVector { CIVector(cgRect: self) }
}
