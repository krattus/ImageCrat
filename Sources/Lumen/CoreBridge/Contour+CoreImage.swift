import Foundation
import CoreGraphics
import CoreImage
import ImageCratCore

extension Contour {
    /// Applies the contour to a grayscale intensity image (0…1 in red).
    func apply(toGray img: CIImage) -> CIImage {
        if isLinear && !antialias { return img }
        let t = table()
        var floats = [Float](repeating: 0, count: 256 * 3)
        for i in 0..<256 { floats[i * 3] = t[i]; floats[i * 3 + 1] = t[i]; floats[i * 3 + 2] = t[i] }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        var out = img.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data, "inputCurvesDomain": CIVector(x: 0, y: 1), "inputColorSpace": sRGBSpace,
        ])
        if antialias { out = out.applyingGaussianBlur(sigma: 0.6).cropped(to: img.extent) }
        return out
    }
    /// Applies the contour to the alpha channel of an image (alpha → contour(alpha)), keeping color.
    func apply(toAlphaOf img: CIImage) -> CIImage {
        if isLinear && !antialias { return img }
        guard let k = Contour.alphaKernel else { return img }
        let lut = Contour.lutImage(table())
        let lutExt = lut.extent
        return k.apply(extent: img.extent, roiCallback: { i, r in i == 1 ? lutExt : r }, arguments: [img, lut]) ?? img
    }
    static func lutImage(_ t: [Float]) -> CIImage {
        var floats = [Float](repeating: 0, count: 256 * 4)
        for i in 0..<256 { floats[i * 4] = t[i]; floats[i * 4 + 1] = t[i]; floats[i * 4 + 2] = t[i]; floats[i * 4 + 3] = 1 }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: 256 * 16, size: CGSize(width: 256, height: 1), format: .RGBAf, colorSpace: nil)
    }
    static let alphaKernel = CIKernel(source: """
    kernel vec4 contourAlpha(sampler src, sampler lut) {
        vec4 c = sample(src, samplerTransform(src, destCoord()));
        float a = clamp(c.a, 0.0, 1.0);
        float na = sample(lut, samplerTransform(lut, vec2(a * 255.0 + 0.5, 0.5))).r;
        vec3 rgb = c.a > 0.0 ? c.rgb / c.a : vec3(0.0);
        return vec4(rgb * na, na);
    }
    """)
    /// Small path preview (0…1 box, y up = 1).
    func previewPath(size: CGSize) -> CGPath {
        let p = CGMutablePath()
        for i in 0...48 {
            let t = Double(i) / 48
            let pt = CGPoint(x: CGFloat(t) * size.width, y: size.height - CGFloat(value(t)) * size.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
